// In-process SDR -> FM demod -> MPX composite library (C ABI).
// See capi-include/mpx_tuner_capi.h. Wraps a device backend (RTL-SDR or, when
// the SDRplay SDK is present, an SDRplay RSP), an FMDemod, and a capture thread.
// Live control setters enqueue commands applied on the capture thread (so all
// device calls stay on one thread). Backend is auto-selected: SDRplay if an RSP
// is attached, else RTL-SDR.

#include "mpx_tuner_capi.h"

#include "dsp/liquid_primitives.h"
#include "fm_demod.h"
#include "rtl_sdr_device.h"
#include "sdrplay_device.h"

#if defined(FM_TUNER_HAS_RTLSDR)
#include <rtl-sdr.h>
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace {
constexpr int kRtlInputRate = 256000;  // RTL-SDR IQ + demod rate

enum Backend { BackendRTL, BackendSDRplay };

enum CmdType { CmdFreq, CmdGain, CmdGainAuto, CmdBandwidth, CmdBias, CmdPPM, CmdRtlAgc };
struct Cmd {
  CmdType type;
  double value;
};
}  // namespace

struct MpxTuner {
  Backend backend = BackendRTL;
  RTLSDRDevice rtl;
  SDRplayDevice sdrplay;
  std::unique_ptr<FMDemod> demod;
  fm_tuner::dsp::liquid::Resampler resampler;  // inputRate -> mpx_rate
  int inputRate = kRtlInputRate;

  MpxTunerSampleCallback cb = nullptr;
  void *ctx = nullptr;
  float mpxGain = 1.0f;
  uint32_t mpxRate;

  std::thread thread;
  std::atomic<bool> running{false};
  std::atomic<bool> alive{false};
  std::atomic<double> signalDbfs{-120.0};

  std::mutex cmdMutex;
  std::vector<Cmd> cmds;

  explicit MpxTuner(uint32_t devIndex, uint32_t rate) : rtl(devIndex), mpxRate(rate) {}

  void enqueue(const Cmd &c) {
    std::lock_guard<std::mutex> lk(cmdMutex);
    cmds.push_back(c);
  }

  void apply(const Cmd &c) {
    const bool sp = (backend == BackendSDRplay);
    switch (c.type) {
      case CmdFreq:
        if (c.value > 0) {
          const uint32_t hz = static_cast<uint32_t>(c.value * 1000.0);
          if (sp) sdrplay.setFrequency(hz); else rtl.setFrequency(hz);
        }
        break;
      case CmdGain:
        if (sp) {
          sdrplay.setGain(c.value);
        } else {
          rtl.setGainMode(true);
          rtl.setGain(static_cast<uint32_t>(std::lround(c.value * 10.0)));
        }
        break;
      case CmdGainAuto:
        if (sp) sdrplay.setGainAuto(c.value != 0.0);
        else rtl.setGainMode(c.value == 0.0);  // auto => manual mode false
        break;
      case CmdBandwidth: {
        const int hz = static_cast<int>(std::lround(c.value * 1000.0));
        if (demod) demod->setBandwidthHz(hz);   // software channel FIR (both backends)
        if (sp) sdrplay.setBandwidthHz(hz);
        else rtl.setTunerBandwidth(static_cast<uint32_t>(hz < 0 ? 0 : hz));
        break;
      }
      case CmdBias:    if (!sp) rtl.setBiasTee(c.value != 0.0); break;          // RTL only
      case CmdPPM:     if (!sp) rtl.setFrequencyCorrection(static_cast<int>(std::lround(c.value))); break;
      case CmdRtlAgc:  if (!sp) rtl.setAGC(c.value != 0.0); break;             // RTL only
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
    std::vector<std::complex<float>> iqc(kBlock);
    std::vector<float> mpx(kBlock);
    std::vector<float> out;
    out.reserve(kBlock);
    std::array<float, fm_tuner::dsp::liquid::Resampler::kMaxOutput> tmp{};

    while (running.load(std::memory_order_relaxed)) {
      drain();
      const bool sp = (backend == BackendSDRplay);
      if ((sp && sdrplay.failed()) || (!sp && rtl.failed())) {
        alive.store(false, std::memory_order_relaxed);
        break;
      }
      size_t n = 0;
      if (sp) {
        n = sdrplay.readIQ(iqc.data(), kBlock);
        if (n == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        demod->processSplitComplex(iqc.data(), mpx.data(), nullptr, n);
      } else {
        n = rtl.readIQ(iq.data(), kBlock);
        if (n == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        demod->processSplit(iq.data(), mpx.data(), nullptr, n);
      }
      signalDbfs.store(demod->getFilteredChannelPowerDbfs(), std::memory_order_relaxed);
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
  int n = 0;
#if defined(FM_TUNER_HAS_RTLSDR)
  n += static_cast<int>(rtlsdr_get_device_count());
#endif
  n += SDRplayDevice::deviceCount();
  return n;
}

MpxTuner *mpxtuner_open(const MpxTunerConfig *cfg, MpxTunerSampleCallback cb,
                        void *ctx, char *err, size_t err_len) {
  auto setErr = [&](const char *m) {
    if (err && err_len) { std::strncpy(err, m, err_len - 1); err[err_len - 1] = '\0'; }
  };
  if (!cfg) { setErr("null config"); return nullptr; }
  const uint32_t rate = cfg->mpx_rate ? cfg->mpx_rate : 192000;
  MpxTuner *t = new (std::nothrow) MpxTuner(cfg->device_index, rate);
  if (!t) { setErr("out of memory"); return nullptr; }
  t->cb = cb;
  t->ctx = ctx;

  // Auto-prefer SDRplay when an RSP is attached; else RTL-SDR.
  const bool useSDRplay = SDRplayDevice::deviceCount() > 0;
  if (useSDRplay) {
    t->backend = BackendSDRplay;
    if (!t->sdrplay.connect(cfg->freq_khz * 1000)) {
      setErr("SDRplay device open failed"); delete t; return nullptr;
    }
    t->inputRate = t->sdrplay.inputRate();
  } else {
    t->backend = BackendRTL;
    if (!t->rtl.connect()) { setErr("no SDR device found"); delete t; return nullptr; }
    t->inputRate = kRtlInputRate;
    t->rtl.setSampleRate(kRtlInputRate);
    t->rtl.setFrequency(cfg->freq_khz * 1000);
    if (cfg->ppm != 0) t->rtl.setFrequencyCorrection(cfg->ppm);
    if (cfg->auto_gain) {
      t->rtl.setGainMode(false);
    } else {
      t->rtl.setGainMode(true);
      t->rtl.setGain(static_cast<uint32_t>(std::lround(cfg->gain_db * 10.0)));
    }
    t->rtl.setAGC(cfg->rtl_agc != 0);
    t->rtl.setBiasTee(cfg->bias_tee != 0);
  }

  t->demod = std::make_unique<FMDemod>(t->inputRate, static_cast<int>(rate));
  t->resampler.init(static_cast<float>(rate) / static_cast<float>(t->inputRate));
  t->mpxGain = static_cast<float>(std::pow(10.0, cfg->mpx_gain_db / 20.0));

  if (cfg->bandwidth_khz > 0) {
    t->demod->setBandwidthHz(cfg->bandwidth_khz * 1000);
    if (useSDRplay) t->sdrplay.setBandwidthHz(cfg->bandwidth_khz * 1000);
    else t->rtl.setTunerBandwidth(static_cast<uint32_t>(cfg->bandwidth_khz * 1000));
  } else if (!useSDRplay) {
    t->rtl.setTunerBandwidth(0);
  }
  if (useSDRplay && !cfg->auto_gain) t->sdrplay.setGain(cfg->gain_db);

  t->running.store(true, std::memory_order_relaxed);
  t->alive.store(true, std::memory_order_relaxed);
  t->thread = std::thread([t] { t->loop(); });
  return t;
}

void mpxtuner_close(MpxTuner *t) {
  if (!t) return;
  t->running.store(false, std::memory_order_relaxed);
  if (t->thread.joinable()) t->thread.join();
  if (t->backend == BackendSDRplay) t->sdrplay.disconnect();
  else t->rtl.disconnect();
  delete t;
}

int mpxtuner_is_alive(const MpxTuner *t) {
  return (t && t->alive.load(std::memory_order_relaxed)) ? 1 : 0;
}

double mpxtuner_signal_dbfs(const MpxTuner *t) {
  return t ? t->signalDbfs.load(std::memory_order_relaxed) : -120.0;
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
