when defined(linux):
  import std/posix

  const
    AtFdcwd = -100.cint
    AtNoAutomount = 0x800.cint
    AtStatxDontSync = 0x4000.cint
    StatxMtime = 0x40.cuint

  type
    StatxTimestamp {.importc: "struct statx_timestamp", header: "<linux/stat.h>".} =
      object
        tv_sec*: int64
        tv_nsec*: uint32
        reserved*: int32

    Statx {.importc: "struct statx", header: "<linux/stat.h>".} = object
      stx_mask*: uint32
      stx_blksize*: uint32
      stx_attributes*: uint64
      stx_nlink*: uint32
      stx_uid*: uint32
      stx_gid*: uint32
      stx_mode*: uint16
      spare0*: array[1, uint16]
      stx_ino*: uint64
      stx_size*: uint64
      stx_blocks*: uint64
      stx_attributes_mask*: uint64
      stx_atime*: StatxTimestamp
      stx_btime*: StatxTimestamp
      stx_ctime*: StatxTimestamp
      stx_mtime*: StatxTimestamp
      stx_rdev_major*: uint32
      stx_rdev_minor*: uint32
      stx_dev_major*: uint32
      stx_dev_minor*: uint32
      stx_mnt_id*: uint64
      stx_dio_mem_align*: uint32
      stx_dio_offset_align*: uint32
      spare3*: array[12, uint64]

  proc statx(
    dirfd: cint,
    pathname: cstring,
    flags: cint,
    mask: cuint,
    statxbuf: ptr Statx,
  ): cint {.importc, header: "<sys/stat.h>".}

  proc statxMTimeUnixNs*(path: string): tuple[ok: bool, ns: int64] =
    ## Returns mtime as Unix nanoseconds using Linux `statx`.
    ##
    ## The call asks only for `STATX_MTIME` and uses `AT_STATX_DONT_SYNC` so
    ## freshness checks do not trigger remote-filesystem synchronization. A
    ## false result means callers must use the portable stdlib fallback.
    var st: Statx
    let rc = statx(
      AtFdcwd,
      path.cstring,
      AtNoAutomount or AtStatxDontSync,
      StatxMtime,
      addr st,
    )
    if rc != 0 or (st.stx_mask and StatxMtime) == 0:
      return (false, 0'i64)
    (true, st.stx_mtime.tv_sec * 1_000_000_000'i64 + int64(st.stx_mtime.tv_nsec))
