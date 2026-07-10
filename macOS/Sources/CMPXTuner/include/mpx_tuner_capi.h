// C ABI for the in-process RTL-SDR -> FM demod -> MPX composite path.
//
// MPX Prime Meter links this directly (no subprocess, no FIFO): it opens the
// device, starts a capture+demod thread, and delivers float MPX blocks via a
// callback. The implementation (mpx_tuner_capi.cpp) wraps the same C++
// RTLSDRDevice + FMDemod the standalone mpx-tuner executable uses. The public
// surface here is pure C so Swift can import it as a Clang module.
//
// Calibration: samples are scaled so 1.0 == 150 kHz FM deviation (the WAV
// path's -6 dB headroom), matching the absolute calibration the Meter's
// analysis expects (fullScaleKHz = 150).
#ifndef MPX_TUNER_CAPI_H
#define MPX_TUNER_CAPI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Number of RTL-SDR devices currently attached (0 if none / unsupported).
/// Cheap USB enumeration; does not open a device. Used to decide whether to
/// default the Meter to SDR input at launch.
int mpxtuner_device_count(void);

/// 1 if an SDRplay RSP is attached (so the auto-selected backend will be
/// SDRplay). Lets the GUI show the right SDR controls before capture starts.
int mpxtuner_sdrplay_present(void);

typedef struct MpxTuner MpxTuner;

/// Delivers a block of mono MPX composite float samples at the configured
/// output rate. Invoked on the tuner's capture thread; the pointer is valid
/// only for the duration of the call.
typedef void (*MpxTunerSampleCallback)(const float *samples, size_t count,
                                       void *ctx);

/// One attached SDR device (either backend), for building a device picker.
typedef struct {
  int backend;      // 1 = RTL-SDR, 2 = SDRplay
  uint32_t index;   // per-backend device index
  char name[64];    // e.g. "SDRplay RSPdx", "RTL-SDR Blog V3"
  char serial[64];  // USB / API serial (stable identity across replug)
} MpxTunerDeviceInfo;

typedef struct {
  uint32_t device_index;  // RTL-SDR device index (usually 0)
  uint32_t freq_khz;      // tune frequency in kHz
  uint32_t mpx_rate;      // output sample rate (192000)
  double mpx_gain_db;     // output headroom; -6.0 => full scale 150 kHz
  double gain_db;         // manual tuner gain (dB); used when auto_gain == 0
  int auto_gain;          // 1 = tuner auto/hardware gain mode
  int bandwidth_khz;      // IF channel bandwidth in kHz (0 = auto / widest)
  int bias_tee;           // 1 = enable RTL-SDR v3 5V bias tee
  int ppm;                // frequency correction (ppm)
  int rtl_agc;            // 1 = RTL2832 digital AGC
  int antenna;            // SDRplay antenna input index (0-based; ignored on RTL)
  int lna;                // SDRplay LNA state (front-end gain reduction step)
  int backend;            // 0 = auto (SDRplay preferred), 1 = RTL-SDR, 2 = SDRplay
  char device_serial[64]; // non-empty: select the device with this serial
} MpxTunerConfig;

/// Serial of the ACTIVE device ("" if unknown). Lets the UI list the unit it
/// is capturing from even when the backend API hides in-use devices from
/// enumeration (SDRplay GetDevices omits selected units).
void mpxtuner_device_serial(const MpxTuner *t, char *buf, size_t len);

/// List attached SDR devices across both backends (SDRplay first, then
/// RTL-SDR). Returns the number written (<= max).
int mpxtuner_list_devices(MpxTunerDeviceInfo *out, int max);

/// Open the device, configure it, and start the capture + demod thread.
/// Returns NULL on failure (no device, allocation, etc.) and writes a message
/// into `err` (when err != NULL and err_len > 0).
MpxTuner *mpxtuner_open(const MpxTunerConfig *cfg, MpxTunerSampleCallback cb,
                        void *ctx, char *err, size_t err_len);

/// Stop the capture thread, close the device, and free. Safe on NULL.
void mpxtuner_close(MpxTuner *t);

/// Like mpxtuner_close but NEVER performs the register-writing RTL-SDR device
/// close -- for process-termination paths, where a dead USB handle would SEGV
/// in libusb and the kernel is about to release the claim anyway.
void mpxtuner_close_fast(MpxTuner *t);

/// 1 while the capture thread is alive; 0 after a fatal device error
/// (e.g. the dongle was unplugged). The GUI polls this to surface a loss.
int mpxtuner_is_alive(const MpxTuner *t);

/// Latest filtered-channel signal level in dBFS (<= 0), a relative RSSI
/// indicator. Most meaningful with manual gain (Auto Gain off); with auto gain
/// the tuner normalizes the level. -120 before the first block.
double mpxtuner_signal_dbfs(const MpxTuner *t);

/// Active backend: 0 = RTL-SDR, 1 = SDRplay.
int mpxtuner_backend(const MpxTuner *t);
/// Number of selectable antenna inputs (1 = none / not applicable).
int mpxtuner_antenna_count(const MpxTuner *t);
/// Human device name, e.g. "SDRplay RSPdx" or "RTL-SDR R820T". Writes into buf.
void mpxtuner_device_name(const MpxTuner *t, char *buf, size_t len);

// Live controls. Thread-safe: each enqueues a command applied on the capture
// thread between IQ blocks, so it never interrupts the MPX stream.
void mpxtuner_set_frequency_khz(MpxTuner *t, uint32_t khz);
void mpxtuner_set_gain_db(MpxTuner *t, double db);  // also forces manual mode
void mpxtuner_set_gain_auto(MpxTuner *t, int on);
void mpxtuner_set_bandwidth_khz(MpxTuner *t, int khz);  // 0 = auto
void mpxtuner_set_bias_tee(MpxTuner *t, int on);
void mpxtuner_set_ppm(MpxTuner *t, int ppm);
void mpxtuner_set_rtl_agc(MpxTuner *t, int on);
void mpxtuner_set_antenna(MpxTuner *t, int index);  // SDRplay antenna input
void mpxtuner_set_lna(MpxTuner *t, int state);      // SDRplay LNA state

#ifdef __cplusplus
}
#endif

#endif  // MPX_TUNER_CAPI_H
