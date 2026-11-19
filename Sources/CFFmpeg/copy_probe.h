#ifndef MPCUT_COPY_PROBE_H
#define MPCUT_COPY_PROBE_H

// Unindexed containers may need an audio decoder to identify the sample
// clock. Video eligibility and timestamps use only headers and parsers.
#define MPCUT_PROBE_DECODERS "aac,aac_latm,ac3,eac3,mp2,mp2float,mp3,mp3float,opus,vorbis"

#endif
