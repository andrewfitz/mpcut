#include "MPProgramMixPCM.h"
#include <stddef.h>

void mp_program_mix_accumulate(const float *input, double *output,
                               int frames, int input_channels, int output_channels,
                               const double *matrix, int lane_count)
{
    if (lane_count <= 0 || frames <= 0 || input_channels <= 0 || output_channels <= 0)
        return;
    double weight = 1.0 / lane_count;
    if (!matrix) {
        if (input_channels != output_channels)
            return;
        for (size_t i = 0; i < (size_t)frames * output_channels; i++)
            output[i] += input[i] * weight;
        return;
    }

    // The preview renders stereo, typically from mono or stereo recordings.
    // Keep the same accumulation order while making these matrix sizes explicit.
    if (output_channels == 2 && input_channels == 1) {
        const double left = matrix[0], right = matrix[1];
        for (size_t frame = 0; frame < (size_t)frames; frame++) {
            double sample = input[frame];
            output[2 * frame] += (0.0 + sample * left) * weight;
            output[2 * frame + 1] += (0.0 + sample * right) * weight;
        }
        return;
    }
    if (output_channels == 2 && input_channels == 2) {
        const double ll = matrix[0], lr = matrix[1];
        const double rl = matrix[2], rr = matrix[3];
        for (size_t frame = 0; frame < (size_t)frames; frame++) {
            double left = input[2 * frame], right = input[2 * frame + 1];
            double sum_left = 0.0, sum_right = 0.0;
            sum_left += left * ll;
            sum_left += right * lr;
            sum_right += left * rl;
            sum_right += right * rr;
            output[2 * frame] += sum_left * weight;
            output[2 * frame + 1] += sum_right * weight;
        }
        return;
    }

    for (size_t frame = 0; frame < (size_t)frames; frame++) {
        for (size_t channel = 0; channel < (size_t)output_channels; channel++) {
            const double *row = matrix + channel * input_channels;
            double sum = 0;
            for (int source = 0; source < input_channels; source++)
                sum += input[frame * input_channels + source] * row[source];
            output[frame * output_channels + channel] += sum * weight;
        }
    }
}
