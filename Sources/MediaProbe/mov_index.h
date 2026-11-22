#ifndef MPCUT_MOV_INDEX_H
#define MPCUT_MOV_INDEX_H

#include <libavformat/avformat.h>
#include <stdbool.h>
#include <CommonCrypto/CommonDigest.h>

typedef struct {
    int fd;
    int64_t payload_start, payload_end;
} MPMOVIndex;

bool mp_mov_open_index(const char *path, const AVFormatContext *file, MPMOVIndex *index);
void mp_mov_hash_edits(const char *path, const AVFormatContext *file, CC_SHA256_CTX **timing);
bool mp_mov_read_at(int fd, int64_t offset, void *buffer, size_t size);

#endif
