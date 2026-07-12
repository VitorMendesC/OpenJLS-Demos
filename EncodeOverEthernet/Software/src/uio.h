/*-----------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- File:        uio.h
-- Description: Minimal UIO (Userspace I/O) access layer.
--
--              Devices are located by name: the requested string is matched
--              as a substring of /sys/class/uio/uioN/name, so a device-tree
--              node called "openjls@43c00000" (UIO name "43c00000.openjls")
--              is found by asking for "openjls". An explicit "/dev/uioN"
--              path is also accepted.
--
--              Interrupts are optional: uio_irq_enable() probes whether the
--              device has one wired; uio_irq_wait() then blocks on it. All
--              register access works without an interrupt.
-----------------------------------------------------------------------------------------------------------*/

#ifndef UIO_H
#define UIO_H

#include <stddef.h>
#include <stdint.h>

struct uio {
    int                fd;
    volatile uint32_t *regs;
    size_t             map_size;
    int                irq_ok;   /* 1 once uio_irq_enable() has succeeded */
    char               dev[64];  /* /dev/uioN                             */
    char               name[64]; /* sysfs name attribute                  */
};

/* Open by name substring or by /dev/uioN path. Returns 0 or -1 (errno set,
 * message on stderr). */
int  uio_open(struct uio *u, const char *name_or_path);
void uio_close(struct uio *u);

/* Unmask the interrupt. Returns 0 and sets irq_ok on success, -1 if the
 * device has no interrupt wired (not fatal — poll instead). */
int uio_irq_enable(struct uio *u);

/* Block until an interrupt or timeout_ms. Returns 1 on interrupt (already
 * re-enabled), 0 on timeout, -1 on error. */
int uio_irq_wait(struct uio *u, int timeout_ms);

static inline uint32_t uio_rd(const struct uio *u, uint32_t off)
{
    return u->regs[off / 4];
}

static inline void uio_wr(const struct uio *u, uint32_t off, uint32_t val)
{
    u->regs[off / 4] = val;
}

#endif /* UIO_H */
