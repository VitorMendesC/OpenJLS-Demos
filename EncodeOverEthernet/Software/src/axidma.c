/*-----------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- File:        axidma.c
-- Description: Minimal AXI DMA direct-register-mode driver. See axidma.h.
-----------------------------------------------------------------------------------------------------------*/

#include "axidma.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static void msleep_short(void)
{
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 }; /* 100 us */

    nanosleep(&ts, NULL);
}

static int64_t now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int axidma_open(struct axidma *d, const char *name_or_path)
{
    memset(d, 0, sizeof(*d));

    if (uio_open(&d->uio, name_or_path) != 0)
        return -1;

    if (axidma_reset(d) != 0) {
        uio_close(&d->uio);
        return -1;
    }

    /* Interrupt is a nice-to-have; polling works without it. */
    if (uio_irq_enable(&d->uio) == 0)
        fprintf(stderr, "axidma: %s: interrupt available, waits will sleep on it\n", d->uio.name);
    else
        fprintf(stderr, "axidma: %s: no interrupt wired, waits will poll\n", d->uio.name);

    return 0;
}

void axidma_close(struct axidma *d)
{
    uio_close(&d->uio);
}

int axidma_reset(struct axidma *d)
{
    const int64_t deadline = now_ms() + 100;

    /* Either channel's reset bit resets the whole engine (PG021); set both
     * for clarity and wait for self-clear. */
    uio_wr(&d->uio, AXIDMA_CR(AXIDMA_MM2S), AXIDMA_CR_RESET);
    uio_wr(&d->uio, AXIDMA_CR(AXIDMA_S2MM), AXIDMA_CR_RESET);

    while ((uio_rd(&d->uio, AXIDMA_CR(AXIDMA_MM2S)) & AXIDMA_CR_RESET) != 0 ||
           (uio_rd(&d->uio, AXIDMA_CR(AXIDMA_S2MM)) & AXIDMA_CR_RESET) != 0) {
        if (now_ms() > deadline) {
            fprintf(stderr, "axidma: reset did not complete — check that the DMA clock is running\n");
            return -1;
        }
        msleep_short();
    }

    return 0;
}

int axidma_start(struct axidma *d, uint32_t chan, uint64_t phys, uint32_t len)
{
    if (len == 0)
        return -1;

    /* Run the channel with interrupts on completion/error enabled, clear any
     * stale completion flags, then program address and length — the length
     * write starts the transfer. */
    uio_wr(&d->uio, AXIDMA_CR(chan), AXIDMA_CR_RS | AXIDMA_CR_IOC_IRQ | AXIDMA_CR_ERR_IRQ);
    uio_wr(&d->uio, AXIDMA_SR(chan), AXIDMA_SR_IOC | AXIDMA_SR_ERR);
    uio_wr(&d->uio, AXIDMA_ADDR(chan), (uint32_t)phys);
    if ((phys >> 32) != 0)
        uio_wr(&d->uio, AXIDMA_MSB(chan), (uint32_t)(phys >> 32));
    uio_wr(&d->uio, AXIDMA_LEN(chan), len);

    return 0;
}

int axidma_wait(struct axidma *d, uint32_t chan, int timeout_ms)
{
    const int64_t deadline = now_ms() + timeout_ms;

    for (;;) {
        const uint32_t sr = uio_rd(&d->uio, AXIDMA_SR(chan));

        if ((sr & AXIDMA_SR_ANY_ERR) != 0) {
            fprintf(stderr, "axidma: %s error on %s: SR=0x%08x%s%s%s\n",
                    d->uio.name, (chan == AXIDMA_MM2S) ? "MM2S" : "S2MM", sr,
                    (sr & AXIDMA_SR_INT_ERR) ? " [internal: TLAST missing / early?]" : "",
                    (sr & AXIDMA_SR_SLV_ERR) ? " [slave]" : "",
                    (sr & AXIDMA_SR_DEC_ERR) ? " [decode: bad buffer address?]" : "");
            return -1;
        }

        if ((sr & AXIDMA_SR_IOC) != 0) {
            uio_wr(&d->uio, AXIDMA_SR(chan), AXIDMA_SR_IOC);
            return 0;
        }

        if (now_ms() > deadline)
            return -2;

        /* Sleep on the interrupt when available (whichever DMA IRQ is wired
         * to the UIO node — status is re-read on every wakeup), otherwise
         * poll with a short nap. */
        if (d->uio.irq_ok)
            uio_irq_wait(&d->uio, 10);
        else
            msleep_short();
    }
}
