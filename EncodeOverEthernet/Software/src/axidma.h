/*-----------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- File:        axidma.h
-- Description: Minimal driver for the Xilinx AXI DMA (PG021) in Direct
--              Register (simple) mode — Scatter/Gather disabled.
--
--              One transfer per channel at a time:
--                MM2S reads `len` bytes at `phys` and streams them out
--                (pixels into the encoder).
--                S2MM writes the incoming stream at `phys` until TLAST or
--                `maxlen` bytes (encoded stream out of the encoder); the
--                actual byte count is read back after completion.
--
--              Completion is detected by polling the status register; if the
--              UIO node has an interrupt wired, the poll loop sleeps on it
--              instead of busy-waiting (either of the DMA's two IRQs works —
--              status is re-checked on every wakeup).
-----------------------------------------------------------------------------------------------------------*/

#ifndef AXIDMA_H
#define AXIDMA_H

#include <stdint.h>

#include "uio.h"

/* Register offsets (PG021). MM2S at 0x00, S2MM at 0x30. */
#define AXIDMA_MM2S 0x00u
#define AXIDMA_S2MM 0x30u

#define AXIDMA_CR(chan)   ((chan) + 0x00u) /* control                        */
#define AXIDMA_SR(chan)   ((chan) + 0x04u) /* status                         */
#define AXIDMA_ADDR(chan) ((chan) + 0x18u) /* MM2S_SA / S2MM_DA              */
#define AXIDMA_MSB(chan)  ((chan) + 0x1Cu) /* upper 32 address bits          */
#define AXIDMA_LEN(chan)  ((chan) + 0x28u) /* length in bytes; write starts  */

/* Control bits */
#define AXIDMA_CR_RS       (1u << 0)
#define AXIDMA_CR_RESET    (1u << 2)
#define AXIDMA_CR_IOC_IRQ  (1u << 12)
#define AXIDMA_CR_ERR_IRQ  (1u << 14)

/* Status bits */
#define AXIDMA_SR_HALTED   (1u << 0)
#define AXIDMA_SR_IDLE     (1u << 1)
#define AXIDMA_SR_INT_ERR  (1u << 4)
#define AXIDMA_SR_SLV_ERR  (1u << 5)
#define AXIDMA_SR_DEC_ERR  (1u << 6)
#define AXIDMA_SR_IOC      (1u << 12)
#define AXIDMA_SR_ERR      (1u << 14)
#define AXIDMA_SR_ANY_ERR  (AXIDMA_SR_INT_ERR | AXIDMA_SR_SLV_ERR | AXIDMA_SR_DEC_ERR | AXIDMA_SR_ERR)

struct axidma {
    struct uio uio;
};

/* Open the DMA's UIO device (name substring or /dev/uioN) and reset the
 * engine. Returns 0 or -1. */
int  axidma_open(struct axidma *d, const char *name_or_path);
void axidma_close(struct axidma *d);

/* Soft-reset the whole engine (both channels). Returns 0, or -1 if the
 * reset bit never self-cleared. */
int axidma_reset(struct axidma *d);

/* Start a transfer on `chan` (AXIDMA_MM2S or AXIDMA_S2MM). `len` must be
 * nonzero and within the length-register width configured in the block
 * design. Returns 0 or -1. */
int axidma_start(struct axidma *d, uint32_t chan, uint64_t phys, uint32_t len);

/* Wait for completion (IOC) on `chan`. Returns 0 on completion, -1 on DMA
 * error (status printed to stderr), -2 on timeout. */
int axidma_wait(struct axidma *d, uint32_t chan, int timeout_ms);

/* Bytes actually transferred by the last completed transfer on `chan`
 * (for S2MM this is the encoded length when TLAST ended the transfer). */
static inline uint32_t axidma_bytes(struct axidma *d, uint32_t chan)
{
    return uio_rd(&d->uio, AXIDMA_LEN(chan));
}

#endif /* AXIDMA_H */
