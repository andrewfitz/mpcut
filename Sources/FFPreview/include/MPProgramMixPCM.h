#ifndef MP_PROGRAM_MIX_PCM_H
#define MP_PROGRAM_MIX_PCM_H

/// Add interleaved PCM from one selected lane to an aligned program block.
/// The optional matrix has one row per output channel and one column per input channel.
/// A null matrix uses the input channels as-is.
void mp_program_mix_accumulate(const float * _Nonnull input, double * _Nonnull output,
                               int frames, int input_channels, int output_channels,
                               const double * _Nullable matrix, int lane_count);

#endif
