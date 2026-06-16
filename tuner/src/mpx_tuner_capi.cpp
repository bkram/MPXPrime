// In-process RTL-SDR -> FM demod -> MPX composite library (C ABI).
// See capi-include/mpx_tuner_capi.h. Wraps RTLSDRDevice + FMDemod + a capture
// thread; live control setters enqueue commands applied on the capture thread
// (so all rtlsdr_* calls stay on one thread, matching the standalone helper).

#include "mpx_tuner_capi.h"

#include "dsp/liquid_primitives.h"
#include "fm_demod.h"
#include "rtl_sdr_device.h"

#if defined(FM_TUNER_HAS_RTLSDR)
#include <rtl-sdr.h>
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace {
constexpr int kInputRate = 256000;  // IQ + demod rate (matches mpx-tuner)

enum CmdType {
  CmdFreq,
  CmdGain,
  CmdGainAuto,
  CmdBandwidth,
  CmdBias,
  CmdPPM,
  CmdRtlAgc
};
struct Cmd {
  CmdType type;
  double value;
};
}  // namespace

struct MpxTuner {
  RTLSDRDevice device;
  FMDemod demod;
  fm_tuner::dsp::liquid::Resampler resampler;  // 256 kHz -> mpx_rate
  MpxTunerSampleCallback cb = nullptr;
  void *ctx = nullptr;
  float mpxGain = 1.0f;
  uint32_t mpxRate;

  std::thread thread;
  std::atomic<bool> running{false};
  std::atomic<bool> alive{false};

  std::mutex cmdMutex;
  std::vector<Cmd> cmds;

  MpxTuner(uint32_t devIndex, uint32_t rate)
      : device(devIndex), demod(kInputRate, static_cast<int>(rate)),
        mpxRate(rate) {}

  void enqueue(const Cmd &c) {
    std::lock_guard<std::mutex> lk(cmdMutex);
    cmds.push_back(c);
  }

  void apply(const Cmd &c) {
    switch (c.type) {
      case CmdFreq:
        if (c.value > 0)
          device.setFrequency(static_cast<uint32_t>(c.value * 1000.0));
        break;
      case CmdGain:
        device.setGainMode(true);
        device.setGain(static_cast<uint32_t>(std::lround(c.value * 10.0)));
        break;
      case CmdGainAuto:
        // auto on (value != 0) => tuner picks gain => manual mode false.
        device.setGainMode(c.value == 0.0);
        break;
      case CmdBandwidth: {
        const int hz = static_cast<int>(std::lround(c.value * 1000.0));
        demod.setBandwidthHz(hz);  // software channel FIR (binding @ 256 kHz)
        device.setTunerBandwidth(static_cast<uint32_t>(hz < 0 ? 0 : hz));
        break;
      }
      case CmdBias:
        device.setBiasTee(c.value != 0.0);
        break;
      case CmdPPM:
        device.setFrequencyCorrection(static_cast<int>(std::lround(c.value)));
        break;
      case CmdRtlAgc:
        device.setAGC(c.value != 0.0);
        break;
    }
  }

  void drain() {
    std::vector<Cmd> local;
    {
      std::lock_guard<std::mutex> lk(cmdMutex);
      local.swap(cmds);
    }
    for (const auto &c : local) apply(c);
  }

  void loop() {
    const size_t kBlock = 8192;
    std::vector<uint8_t> iq(kBlock * 2);
    std::vector<float> mpx(kBlock);
    std::vector<float> out;
    out.reserve(kBlock);
    std::array<float, fm_tuner::dsp::liquid::Resampler::kMaxOutput> tmp{};

    while (running.load(std::memory_order_relaxed)) {
      drain();
      if (device.failed()) {
        alive.store(false, std::memory_order_relaxed);
        break;
      }
      const size_t n = device.readIQ(iq.data(), kBlock);
      if (n == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        continue;
      }
      demod.processSplit(iq.data(), mpx.data(), nullptr, n);
      out.clear();
      for (size_t i = 0; i < n; i++) {
        const std::uint32_t produced = resampler.execute(mpx[i] * mpxGain, tmp);
        for (std::uint32_t p = 0; p < produced; p++) out.push_back(tmp[p]);
      }
      if (!out.empty() && cb) cb(out.data(), out.size(), ctx);
    }
    alive.store(false, std::memory_order_relaxed);
  }
};

extern "C" {

int mpxtuner_device_count(void) {
#if defined(FM_TUNER_HAS_RTLSDR)
  return static_cast<int>(rtlsdr_get_device_count());
#else
  return 0;
#endif
}

MpxTuner *mpxtuner_open(const MpxTunerConfig *cfg, MpxTunerSampleCallback cb,
                        void *ctx, char *err, size_t err_len) {
  auto setErr = [&](const char *m) {
    if (err && err_len) {
      std::strncpy(err, m, err_len - 1);
      err[err_len - 1] = '\0';
    }
  };
  if (!cfg) {
    setErr("null config");
    return nullptr;
  }
  const uint32_t rate = cfg->mpx_rate ? cfg->mpx_rate : 192000;
  MpxTuner *t = new (std::nothrow) MpxTuner(cfg->device_index, rate);
  if (!t) {
    setErr("out of memory");
    return nullptr;
  }
  if (!t->device.connect()) {
    setErr("no RTL-SDR device found");
    delete t;
    return nullptr;
  }
  t->cb = cb;
  t->ctx = ctx;
  t->mpxGain = static_cast<float>(std::pow(10.0, cfg->mpx_gain_db / 20.0));
  t->resampler.init(static_cast<float>(rate) / static_cast<float>(kInputRate));

  t->device.setSampleRate(kInputRate);
  t->device.setFrequency(cfg->freq_khz * 1000);
  if (cfg->ppm != 0) t->device.setFrequencyCorrection(cfg->ppm);
  if (cfg->auto_gain) {
    t->device.setGainMode(false);  // hardware / auto gain
  } else {
    t->device.setGainMode(true);
    t->device.setGain(static_cast<uint32_t>(std::lround(cfg->gain_db * 10.0)));
  }
  t->device.setAGC(cfg->rtl_agc != 0);
  t->device.setBiasTee(cfg->bias_tee != 0);
  // bandwidth 0 = auto: leave the demod at its construction default (matches
  // the historical full-MPX behavior); only narrow the channel when asked.
  if (cfg->bandwidth_khz > 0) {
    t->demod.setBandwidthHz(cfg->bandwidth_khz * 1000);
    t->device.setTunerBandwidth(static_cast<uint32_t>(cfg->bandwidth_khz * 1000));
  } else {
    t->device.setTunerBandwidth(0);
  }

  t->running.store(true, std::memory_order_relaxed);
  t->alive.store(true, std::memory_order_relaxed);
  t->thread = std::thread([t] { t->loop(); });
  return t;
}

void mpxtuner_close(MpxTuner *t) {
  if (!t) return;
  t->running.store(false, std::memory_order_relaxed);
  if (t->thread.joinable()) t->thread.join();
  t->device.disconnect();
  delete t;
}

int mpxtuner_is_alive(const MpxTuner *t) {
  return (t && t->alive.load(std::memory_order_relaxed)) ? 1 : 0;
}

void mpxtuner_set_frequency_khz(MpxTuner *t, uint32_t khz) {
  if (t) t->enqueue({CmdFreq, static_cast<double>(khz)});
}
void mpxtuner_set_gain_db(MpxTuner *t, double db) {
  if (t) t->enqueue({CmdGain, db});
}
void mpxtuner_set_gain_auto(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdGainAuto, on ? 1.0 : 0.0});
}
void mpxtuner_set_bandwidth_khz(MpxTuner *t, int khz) {
  if (t) t->enqueue({CmdBandwidth, static_cast<double>(khz)});
}
void mpxtuner_set_bias_tee(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdBias, on ? 1.0 : 0.0});
}
void mpxtuner_set_ppm(MpxTuner *t, int ppm) {
  if (t) t->enqueue({CmdPPM, static_cast<double>(ppm)});
}
void mpxtuner_set_rtl_agc(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdRtlAgc, on ? 1.0 : 0.0});
}

}  // extern "C"
