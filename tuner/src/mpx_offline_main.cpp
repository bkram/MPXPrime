// mpx-offline -- run the MPX Prime Meter's SDR demod chain on synthetic or
// recorded IQ, with no device attached. Two jobs, both from meter-plan.md:
//
//  1. Phase-dispersion characterization (A3): synthesize a composite whose
//     pilot-to-RDS phase is EXACTLY known, FM-modulate it to IQ, run it
//     through the same FMDemod + ComplexDecimator + Resampler wiring the
//     shipped capi uses, and replay the result through `MPXPrimeMeter
//     --stdin`. measured angle - injected angle = the chain's dispersion
//     between 19 and 57 kHz, per output rate and per path.
//
//  2. Same-IQ path A/B (B2): replay ONE recorded packed-uint8 IQ capture
//     through the packed byte-exact demod path and through the unpack ->
//     complex path, so the two can be compared with the different-capture
//     variable removed (the 2026-08-31 bench compared separate captures).
//
// The wiring below deliberately mirrors mpx_tuner_capi.cpp's loop() and
// mpxtuner_open(): demod always at 256 kHz, ComplexDecimator bridging any
// wider capture rate, liquid Resampler to the MPX output rate, and the
// bandwidth setting left UNAPPLIED when 0 -- reproducing the shipped "auto"
// behavior (see plan.md: the FMDemod ctor leaves mode 0 uninstalled). Keep it
// in sync with the capi when that wiring changes.
//
// Output is raw little-endian int16 mono at --mpx-rate, scaled by
// --mpx-gain-db (default -6 dB so int16 full scale = 150 kHz deviation),
// exactly the convention `MPXPrimeMeter --stdin --full-scale-khz 150` expects.

#include "fm_demod.h"

#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kDemodRate = 256000;  // the RTL FM demod chain rate (capi)
constexpr double kPi = 3.14159265358979323846;

void usage(const char *argv0) {
  std::fprintf(stderr,
    "usage: %s (--synth-phase <deg> | --iq-in <path>) [options]\n"
    "  --synth-phase <deg>   synthesize pilot (9%%) + CW RDS subcarrier (4%%) locked\n"
    "                        at <deg> to the pilot's 3rd harmonic, FM-modulated to IQ\n"
    "  --iq-in <path>        packed uint8 IQ file (rtl_sdr format) at --capture-rate\n"
    "  --direct              synth only: skip FM/demod entirely and emit the clean\n"
    "                        composite at --mpx-rate (meter-side ground truth)\n"
    "  --path packed|complex demod input path (default packed; packed needs factor 1,\n"
    "                        complex unpacks bytes exactly like the capi wide path)\n"
    "  --capture-rate <Hz>   IQ rate; must be 256000 x an integer (default 256000)\n"
    "  --bandwidth-khz <k>   demod channel bandwidth; 0 = shipped auto, i.e. NO mode\n"
    "                        filter installed (default 0)\n"
    "  --mpx-rate <Hz>       composite output rate via the capi resampler (default\n"
    "                        192000; 256000 = ratio-1 resample, still through it)\n"
    "  --no-resample         bypass the resampler stage (output at 256000)\n"
    "  --mpx-gain-db <dB>    output scale (default -6: int16 full scale = 150 kHz)\n"
    "  --seconds <s>         synth duration (default 90)\n"
    "  --tone-amp <a>        synth mono program tone at 997 Hz, amplitude 0..1 of\n"
    "                        75 kHz deviation (default 0.6; keeps the FM modulation\n"
    "                        index realistic so the demod's DC blockers are benign)\n"
    "  --out <path>          raw int16 LE output (default stdout)\n",
    argv0);
}

struct Args {
  bool synth = false;
  double synthPhaseDeg = 0.0;
  std::string iqIn;
  bool direct = false;
  bool pathComplex = false;
  int captureRate = kDemodRate;
  int bandwidthKHz = 0;
  int mpxRate = 192000;
  bool noResample = false;
  double mpxGainDb = -6.0;
  double seconds = 90.0;
  double toneAmp = 0.6;
  std::string out;
};

// Composite synthesizer: pilot 9% + CW 57 kHz subcarrier at a known phase to
// the pilot's third harmonic, plus a mono program tone. Units: 1.0 = 75 kHz
// deviation (the demod's own convention, FMDemod::setDeviation), so pilot
// reads 6.75 kHz on the replay. A CW subcarrier (not shaped biphase) is
// deliberate: the phase meter's V&V squaring handles it identically and the
// coherence stays near 1, so the angle is measured to a fraction of a degree.
//
// The program tone is NOT decoration. Pilot + RDS alone deviate the carrier
// ~10 kHz peak -- a quasi-CW FM signal whose energy sits AT 0 Hz, which the
// demod's IQ DC blockers then partially remove, distorting both the level
// (measured 5.5x hot) and the subcarrier phase (30 deg in read 10 deg out).
// A real station never presents that signal: program spreads the carrier.
// 60% mono at 997 Hz gives a realistic modulation index so the DC blockers
// see what they see on air; it lives far below the 19/57 kHz measurement.
struct CompositeSynth {
  double theta = 0.0;      // pilot phase
  double thetaTone = 0.0;  // program tone phase
  double dTheta;           // per-sample pilot increment
  double dThetaTone;
  double phi;              // injected RDS phase (rad), vs sin(3*theta)
  double toneAmp;
  CompositeSynth(double sampleRate, double phaseDeg, double toneAmplitude)
      : dTheta(2.0 * kPi * 19000.0 / sampleRate),
        dThetaTone(2.0 * kPi * 997.0 / sampleRate),
        phi(phaseDeg * kPi / 180.0), toneAmp(toneAmplitude) {}
  float next() {
    const double x = toneAmp * std::sin(thetaTone) + 0.09 * std::sin(theta) +
                     0.04 * std::sin(3.0 * theta + phi);
    theta += dTheta;
    if (theta > 2.0 * kPi) theta -= 2.0 * kPi;
    thetaTone += dThetaTone;
    if (thetaTone > 2.0 * kPi) thetaTone -= 2.0 * kPi;
    return static_cast<float>(x);
  }
};

// FM modulator to packed uint8 IQ, quantized exactly as an RTL delivers it so
// the packed and complex paths see byte-identical input.
struct FMModulator {
  double acc = 0.0;
  double k;
  explicit FMModulator(double sampleRate) : k(2.0 * kPi * 75000.0 / sampleRate) {}
  void next(float x, uint8_t *outIQ) {
    acc += k * static_cast<double>(x);
    if (acc > kPi) acc -= 2.0 * kPi;
    if (acc < -kPi) acc += 2.0 * kPi;
    const double i = std::cos(acc), q = std::sin(acc);
    const long ib = std::lround(i * 127.5 + 127.5);
    const long qb = std::lround(q * 127.5 + 127.5);
    outIQ[0] = static_cast<uint8_t>(ib < 0 ? 0 : (ib > 255 ? 255 : ib));
    outIQ[1] = static_cast<uint8_t>(qb < 0 ? 0 : (qb > 255 ? 255 : qb));
  }
};

bool writeInt16(std::FILE *f, const float *x, size_t n, float gain) {
  std::vector<int16_t> buf(n);
  for (size_t i = 0; i < n; i++) {
    float v = x[i] * gain;
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    buf[i] = static_cast<int16_t>(std::lround(v * 32767.0f));
  }
  return std::fwrite(buf.data(), sizeof(int16_t), n, f) == n;
}

}  // namespace

int main(int argc, char **argv) {
  Args a;
  for (int i = 1; i < argc; i++) {
    const std::string s = argv[i];
    auto next = [&](const char *what) -> const char * {
      if (i + 1 >= argc) { std::fprintf(stderr, "%s needs a value\n", what); std::exit(2); }
      return argv[++i];
    };
    if (s == "--synth-phase") { a.synth = true; a.synthPhaseDeg = std::atof(next("--synth-phase")); }
    else if (s == "--iq-in") a.iqIn = next("--iq-in");
    else if (s == "--direct") a.direct = true;
    else if (s == "--path") {
      const std::string p = next("--path");
      if (p == "complex") a.pathComplex = true;
      else if (p == "packed") a.pathComplex = false;
      else { std::fprintf(stderr, "--path must be packed or complex\n"); return 2; }
    }
    else if (s == "--capture-rate") a.captureRate = std::atoi(next("--capture-rate"));
    else if (s == "--bandwidth-khz") a.bandwidthKHz = std::atoi(next("--bandwidth-khz"));
    else if (s == "--mpx-rate") a.mpxRate = std::atoi(next("--mpx-rate"));
    else if (s == "--no-resample") a.noResample = true;
    else if (s == "--mpx-gain-db") a.mpxGainDb = std::atof(next("--mpx-gain-db"));
    else if (s == "--seconds") a.seconds = std::atof(next("--seconds"));
    else if (s == "--tone-amp") a.toneAmp = std::atof(next("--tone-amp"));
    else if (s == "--out") a.out = next("--out");
    else if (s == "-h" || s == "--help") { usage(argv[0]); return 0; }
    else { std::fprintf(stderr, "unknown argument: %s\n", s.c_str()); usage(argv[0]); return 2; }
  }

  if (!a.synth && a.iqIn.empty()) { usage(argv[0]); return 2; }
  if (a.synth && !a.iqIn.empty()) {
    std::fprintf(stderr, "--synth-phase and --iq-in are mutually exclusive\n");
    return 2;
  }
  if (a.direct && !a.synth) {
    std::fprintf(stderr, "--direct needs --synth-phase\n");
    return 2;
  }
  if (a.captureRate < kDemodRate || a.captureRate % kDemodRate != 0) {
    std::fprintf(stderr, "--capture-rate must be a positive multiple of %d\n", kDemodRate);
    return 2;
  }
  const int factor = a.captureRate / kDemodRate;
  if (!a.pathComplex && factor != 1) {
    std::fprintf(stderr, "the packed path only runs at factor 1 (capture rate %d); "
                         "use --path complex for wide rates\n", kDemodRate);
    return 2;
  }

  std::FILE *outF = stdout;
  if (!a.out.empty()) {
    outF = std::fopen(a.out.c_str(), "wb");
    if (!outF) { std::fprintf(stderr, "cannot open output '%s'\n", a.out.c_str()); return 1; }
  }
  const float gain = static_cast<float>(std::pow(10.0, a.mpxGainDb / 20.0));

  // Ground-truth mode: the composite straight into the meter, no tuner chain.
  if (a.direct) {
    CompositeSynth synth(a.mpxRate, a.synthPhaseDeg, a.toneAmp);
    const size_t total = static_cast<size_t>(a.seconds * a.mpxRate);
    std::vector<float> block(8192);
    size_t done = 0;
    while (done < total) {
      const size_t n = std::min(block.size(), total - done);
      for (size_t k = 0; k < n; k++) block[k] = synth.next();
      if (!writeInt16(outF, block.data(), n, gain)) break;
      done += n;
    }
    if (outF != stdout) std::fclose(outF);
    return 0;
  }

  // The shipped wiring (mirror mpxtuner_open + MpxTuner::loop).
  FMDemod demod(kDemodRate, 48000);
  if (a.bandwidthKHz > 0) demod.setBandwidthHz(a.bandwidthKHz * 1000);
  fm_tuner::dsp::liquid::ComplexDecimator iqDecim;
  iqDecim.init(static_cast<std::uint32_t>(factor));
  fm_tuner::dsp::liquid::Resampler resampler;
  resampler.init(static_cast<float>(a.mpxRate) / static_cast<float>(kDemodRate));
  std::array<float, fm_tuner::dsp::liquid::Resampler::kMaxOutput> tmp{};

  std::FILE *iqF = nullptr;
  if (!a.iqIn.empty()) {
    iqF = std::fopen(a.iqIn.c_str(), "rb");
    if (!iqF) { std::fprintf(stderr, "cannot open IQ input '%s'\n", a.iqIn.c_str()); return 1; }
  }

  CompositeSynth synth(a.captureRate, a.synthPhaseDeg, a.toneAmp);
  FMModulator mod(a.captureRate);

  const size_t kBlock = 8192;  // IQ samples per block, like the capture loop
  std::vector<uint8_t> iq(kBlock * 2);
  std::vector<std::complex<float>> iqc(kBlock);
  std::vector<std::complex<float>> iqNarrow(kBlock);
  std::vector<float> mpx(kBlock);
  std::vector<float> resampled;
  resampled.reserve(kBlock);

  size_t remaining = a.synth
      ? static_cast<size_t>(a.seconds * a.captureRate)
      : static_cast<size_t>(-1);

  while (remaining > 0) {
    size_t got = 0;
    if (a.synth) {
      got = std::min(kBlock, remaining);
      for (size_t k = 0; k < got; k++) mod.next(synth.next(), &iq[k * 2]);
      remaining -= got;
    } else {
      got = std::fread(iq.data(), 2, kBlock, iqF);
      if (got == 0) break;
    }

    size_t n = 0;
    if (!a.pathComplex) {
      // Factor 1, packed: the byte-exact original path (capi default).
      n = got;
      demod.processSplit(iq.data(), mpx.data(), nullptr, n);
    } else {
      // Wide path: unpack with the capi's normalization, decimate, demod.
      for (size_t k = 0; k < got; k++) {
        iqc[k] = std::complex<float>(
            (static_cast<float>(iq[k * 2]) - 127.5f) / 127.5f,
            (static_cast<float>(iq[k * 2 + 1]) - 127.5f) / 127.5f);
      }
      n = iqDecim.executeComplexIn(iqc.data(), got, iqNarrow.data(), iqNarrow.size());
      if (n == 0) continue;
      demod.processSplitComplex(iqNarrow.data(), mpx.data(), nullptr, n);
    }

    if (a.noResample) {
      if (!writeInt16(outF, mpx.data(), n, gain)) break;
    } else {
      resampled.clear();
      for (size_t i = 0; i < n; i++) {
        const std::uint32_t produced = resampler.execute(mpx[i], tmp);
        for (std::uint32_t p = 0; p < produced; p++) resampled.push_back(tmp[p]);
      }
      if (!resampled.empty() &&
          !writeInt16(outF, resampled.data(), resampled.size(), gain)) break;
    }
  }

  if (iqF) std::fclose(iqF);
  if (outF != stdout) std::fclose(outF);
  return 0;
}
