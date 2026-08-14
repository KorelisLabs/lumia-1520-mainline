# The zero-byte module, and the silent `EINVAL`

For most of a session the WCD9320 module would not autoload. `modprobe` failed
with `Invalid argument` and **dmesg said nothing at all**. Inserting the same
build by hand from `/tmp` always worked. Three separate explanations were
written down and two of them were wrong, so this records what was actually
measured, what it rules out, and what remains unproven.

## What it turned out to be

`/lib/modules/6.16.12/kernel/drivers/slimbus/wcd9320.ko` was **zero bytes**.

```
Size: 0    Blocks: 0    regular empty file
sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

That hash is the SHA-256 of the empty string. An empty file is not an ELF
object, so the loader rejects it — and the rejection happens early enough that
nothing is logged, which is exactly the signature that made this hard to see:
`modprobe` reports `EINVAL` and the kernel ring buffer stays silent.

It also explains the pattern that looked so strange at the time. Loading from
`/tmp` worked because that copy was intact; loading from `/lib/modules` failed
because that copy was empty. Nothing about compression, timing or the loader
was involved.

## Two wrong explanations, and why they looked right

**"The kernel's zstd decompressor rejects our `.ko.zst`."** The first failure
was on a compressed module, `CONFIG_MODULE_DECOMPRESS=y` was set, and
`module_decompress()` does return `-EINVAL` without logging — a perfect fit.
It was disproved the moment an *uncompressed* `.ko` failed the same way at
r139. Compression was never the variable; the `/lib/modules` copy was empty in
both cases.

**"Autoload is fixed."** r138 autoloaded at t=47.8 s from a plain `.ko`, and
that was written up as the fix. r139 had the identical arrangement and did not
autoload. One success is not a fix. What actually differed was whether the file
in `/lib/modules` happened to be intact at the time.

A third guess — that unclean shutdowns had damaged the rootfs — rested on
`EXT4-fs (loop0p1): warning: mounting unchecked fs, running e2fsck is
recommended`. That warning is about **`/boot`**, a journal-less ext2 filesystem
where it is routine, and never referred to the root filesystem at all.

## What the evidence establishes

Measured before anything was changed:

| observation | rules out |
|---|---|
| `Filesystem state: clean` on `/dev/loop0p2` | corruption; `e2fsck` was never warranted |
| size 0 **and blocks 0** | a truncated write — no extent was ever allocated |
| mtime fixed at the install moment, never later | written-then-damaged |
| 10% used, 9.5 G free | `ENOSPC` |
| reinstall from the same path worked first time | a systematically broken deploy path |
| no recurrence across install, reboot, 24 h uptime | an ongoing fault |

So: a **one-off zero-length write at install time**, not filesystem damage.
No repair was run, because none was called for.

## What remains unproven

**Why that install wrote zero bytes.** Its output was never captured — the
`sha256sum` in that command was not checked at the time — and the moment is
gone. Candidates that fit but cannot now be distinguished: an empty or
partially-transferred source file at that instant, or an `install` whose source
was mid-write. Nothing rules either in.

This is recorded as unexplained rather than closed. What makes it not matter
much in practice is that the failure is now *impossible to miss* rather than
merely unlikely: every install is verified by size and sha256 against the built
artefact before a reboot, and `wcd9320-coldboot-autoload-evidence.sh` gates on
both, plus on there being no module anywhere outside `/lib/modules` that could
mask the fault by being loaded instead.

## The lesson that generalises

The failure was invisible for three builds because every check was of the form
"did the command return success". `install` returned 0. `depmod` returned 0.
`modprobe` said `Invalid argument` and the kernel said nothing. The first check
that could actually see the problem was the one that read the artefact back and
compared it to what was supposed to be there — the same discipline that
"verify by artefact, never by exit code" already demanded for builds, applied
one step later in the chain.
