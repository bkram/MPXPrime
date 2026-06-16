// mpx-tuner: minimal RTL-SDR -> FM demod -> MPX composite helper for
// MPX Prime Meter. A stripped subset of FM-SDR-Tuner (GPL-3.0,
// https://github.com/bkram/FM-SDR-Tuner) -- only the rtl_sdr capture, FM
// discriminator, and WAV/pipe writer; no XDR server, no audio output, no
// RDS decode, no calibration (the Meter does its own RDS + audio). See
// tuner/README.md and tuner/UPSTREAM_COMMIT.txt for provenance.
//
// Output is the raw FM-discriminator MPX composite (pilot + L-R + RDS),
// 16-bit LE mono, resampled 256 kHz -> the requested rate (192 kHz default),
// with -6 dB headroom so int16 full scale = 150 kHz deviation -- exactly the
// format MPX Prime Meter's StdinInputSource expects.

#include "rtl_sdr_device.h"
#include "fm_demod.h"
#include "wav_writer.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
std::atomic<bool> g_running{true};
void onSignal(int) { g_running.store(false); }

// Apply one live control line to the device (called between IQ blocks, so a
// retune never interrupts the MPX stream). Commands (one per line):
//   freq <kHz>          retune
//   gain <dB>           manual gain (also forces manual mode)
//   gainmode auto|manual
//   agc 0|1             RTL2832 digital AGC
//   ppm <n>             frequency correction
void applyControl(RTLSDRDevice &device, const std::string &line) {
  char verb[32] = {0};
  double value = 0.0;
  char word[32] = {0};
  if (std::sscanf(line.c_str(), "%31s", verb) != 1) return;
  if (std::strcmp(verb, "freq") == 0) {
    if (std::sscanf(line.c_str(), "%*s %lf", &value) == 1 && value > 0)
      device.setFrequency(static_cast<uint32_t>(value * 1000.0));  // kHz -> Hz
  } else if (std::strcmp(verb, "gain") == 0) {
    if (std::sscanf(line.c_str(), "%*s %lf", &value) == 1) {
      device.setGainMode(true);
      device.setGain(static_cast<uint32_t>(std::lround(value * 10.0)));  // dB -> tenths
    }
  } else if (std::strcmp(verb, "gainmode") == 0) {
    if (std::sscanf(line.c_str(), "%*s %31s", word) == 1)
      device.setGainMode(std::strcmp(word, "manual") == 0);
  } else if (std::strcmp(verb, "agc") == 0) {
    if (std::sscanf(line.c_str(), "%*s %lf", &value) == 1)
      device.setAGC(value != 0.0);
  } else if (std::strcmp(verb, "ppm") == 0) {
    if (std::sscanf(line.c_str(), "%*s %lf", &value) == 1)
      device.setFrequencyCorrection(static_cast<int>(std::lround(value)));
  }
}

void usage(const char *argv0) {
  std::fprintf(stderr,
    "usage: %s -f <kHz> [-o <path>] [-d <index>] [-g <dB>] [--mpx-gain-db <dB>] [--mpx-rate <Hz>]\n"
    "  -f, --freq <kHz>      FM frequency in kHz (required)\n"
    "  -o, --output <path>   WAV stream destination (default /dev/stdout; a FIFO works)\n"
    "      --control <fifo>    read live commands from this FIFO (freq/gain/gainmode/agc/ppm)\n"
    "  -d, --device <index>  RTL-SDR device index (default 0)\n"
    "  -g, --gain <dB>       manual tuner gain in dB (omit for auto gain)\n"
    "      --mpx-gain-db <dB>  output headroom (default -6; full scale = 150 kHz)\n"
    "      --mpx-rate <Hz>     output sample rate (default 192000)\n",
    argv0);
}
}  // namespace

int main(int argc, char **argv) {
  constexpr int kInputRate = 256000;  // IQ + demod rate (matches FM-SDR-Tuner)
  long freqKHz = -1;
  std::string output = "/dev/stdout";
  std::string controlPath;  // optional FIFO of live commands (--control)
  uint32_t deviceIndex = 0;
  bool manualGain = false;
  double gainDb = 0.0;
  double mpxGainDb = -6.0;
  uint32_t mpxRate = 192000;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&](const char *name) -> const char * {
      if (i + 1 >= argc) { std::fprintf(stderr, "%s needs a value\n", name); std::exit(2); }
      return argv[++i];
    };
    if (a == "-f" || a == "--freq") freqKHz = std::atol(next("--freq"));
    else if (a == "-o" || a == "--output") output = next("--output");
    else if (a == "--control") controlPath = next("--control");
    else if (a == "-d" || a == "--device") deviceIndex = static_cast<uint32_t>(std::atol(next("--device")));
    else if (a == "-g" || a == "--gain") { manualGain = true; gainDb = std::atof(next("--gain")); }
    else if (a == "--mpx-gain-db") mpxGainDb = std::atof(next("--mpx-gain-db"));
    else if (a == "--mpx-rate") mpxRate = static_cast<uint32_t>(std::atol(next("--mpx-rate")));
    else if (a == "-h" || a == "--help") { usage(argv[0]); return 0; }
    else { std::fprintf(stderr, "unknown argument: %s\n", a.c_str()); usage(argv[0]); return 2; }
  }
  if (freqKHz <= 0) { usage(argv[0]); return 2; }

  std::signal(SIGINT, onSignal);
  std::signal(SIGTERM, onSignal);
  std::signal(SIGPIPE, SIG_IGN);  // reader (Meter) going away shouldn't crash us

  RTLSDRDevice device(deviceIndex);
  if (!device.connect()) {
    std::fprintf(stderr, "mpx-tuner: no RTL-SDR device found (index %u)\n", deviceIndex);
    return 1;
  }
  device.setSampleRate(kInputRate);
  device.setFrequency(static_cast<uint32_t>(freqKHz * 1000));
  if (manualGain) {
    device.setGainMode(true);
    device.setGain(static_cast<uint32_t>(std::lround(gainDb * 10.0)));  // tenths of dB
  } else {
    device.setGainMode(false);  // hardware AGC / auto
  }

  FMDemod demod(kInputRate, 48000);  // ctor defaults: 75 kHz deviation, 194 kHz BW -> full MPX

  WavWriter wav;
  if (!wav.init(output, mpxRate, 1, false, "MPX", kInputRate)) {
    std::fprintf(stderr, "mpx-tuner: could not open output '%s'\n", output.c_str());
    return 1;
  }
  wav.setGain(static_cast<float>(std::pow(10.0, mpxGainDb / 20.0)));

  // Optional live-control FIFO (non-blocking; opening never waits for a writer).
  int controlFd = -1;
  if (!controlPath.empty()) {
    controlFd = open(controlPath.c_str(), O_RDONLY | O_NONBLOCK);
    if (controlFd < 0)
      std::fprintf(stderr, "mpx-tuner: could not open control FIFO '%s'\n", controlPath.c_str());
  }
  std::string controlBuf;

  const size_t kBlock = 8192;  // IQ samples per read
  std::vector<uint8_t> iq(kBlock * 2);
  std::vector<float> mpx(kBlock);

  while (g_running.load()) {
    // Drain + apply any pending control commands between blocks.
    if (controlFd >= 0) {
      char cbuf[256];
      ssize_t cn;
      while ((cn = read(controlFd, cbuf, sizeof(cbuf))) > 0) {
        controlBuf.append(cbuf, static_cast<size_t>(cn));
        size_t nl;
        while ((nl = controlBuf.find('\n')) != std::string::npos) {
          applyControl(device, controlBuf.substr(0, nl));
          controlBuf.erase(0, nl + 1);
        }
      }
    }

    size_t n = device.readIQ(iq.data(), kBlock);
    if (n == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
      continue;
    }
    demod.processSplit(iq.data(), mpx.data(), nullptr, n);
    if (!wav.enqueueMonoFloat(mpx.data(), n)) break;  // output closed
  }

  if (controlFd >= 0) close(controlFd);
  wav.shutdown();
  device.disconnect();
  return 0;
}
