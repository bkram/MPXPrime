// SPM build shim: SPM cannot list sources outside the package root, so
// this includes the canonical tuner source (repo-root tuner/) into the
// CMPXTuner C++ target. Single source of truth stays in tuner/.
#include "../../../tuner/src/mpx_tuner_capi.cpp"
