/*-----------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- File:        udmabuf.h
-- Description: Access layer for u-dma-buf (https://github.com/ikwzm/udmabuf)
--              DMA-coherent buffers.
--
--              Buffers are opened by device name (e.g. "udmabuf-ojls-tx") or
--              discovered by index in /sys/class/u-dma-buf. The mapping is
--              cached for speed; udmabuf_sync_for_device()/_for_cpu() hand
--              ownership between CPU and DMA around each transfer.
-----------------------------------------------------------------------------------------------------------*/

#ifndef UDMABUF_H
#define UDMABUF_H

#include <stddef.h>
#include <stdint.h>

struct udmabuf {
    int      fd;
    uint8_t *mem;
    size_t   size;
    uint64_t phys;
    char     name[64];
};

/* Open by exact device name. Returns 0 or -1 (message on stderr). */
int udmabuf_open(struct udmabuf *b, const char *name);

/* Open the index-th device (alphabetical) in /sys/class/u-dma-buf. */
int udmabuf_open_nth(struct udmabuf *b, int index);

/* Number of u-dma-buf devices present. */
int udmabuf_count(void);

void udmabuf_close(struct udmabuf *b);

/* Cache maintenance before/after DMA. offset/len select the region.
 * _for_device: CPU wrote the data, DMA will read it (flush).
 * _for_cpu:    DMA wrote the data, CPU will read it (invalidate).
 * Return 0 or -1. */
int udmabuf_sync_for_device(const struct udmabuf *b, size_t offset, size_t len);
int udmabuf_sync_for_cpu(const struct udmabuf *b, size_t offset, size_t len);

#endif /* UDMABUF_H */
