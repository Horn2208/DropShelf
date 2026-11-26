#ifndef DROPSHELF_OPUS_SWIFT_SHIM_H
#define DROPSHELF_OPUS_SWIFT_SHIM_H

#include "opus.h"

static inline int dropshelf_opus_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

static inline int dropshelf_opus_get_lookahead(OpusEncoder *enc, opus_int32 *lookahead) {
    return opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(lookahead));
}

#endif
