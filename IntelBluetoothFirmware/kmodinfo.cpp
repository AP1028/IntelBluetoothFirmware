/*
 * kmodinfo.c - supply `_kmod_info`, and C-linkage entry points for it, for
 * toolchains that do not emit them (see build-kext-clt.sh).
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The Xcode project links `MacKernelSDK/Library/x86_64/libkmod.a`, which
 * provides `_kmod_info`. Builds produced directly by clang from the Command
 * Line Tools do not link that archive, so the bundle has no `_kmod_info`
 * symbol. Such a bundle is accepted by OpenCore but rejected by the kernel:
 *
 *     cannot be placed in kernel collection because:
 *         kexts must have a _kmod_info symbol
 *
 * THE SYMBOL MUST BE A PLAIN GLOBAL IN __DATA,__data
 * --------------------------------------------------
 *     $ nm -mS Lilu.kext/Contents/MacOS/Lilu | grep _kmod_info
 *     00000000000206e0 (__DATA,__data) external _kmod_info      # 'D'
 *
 * Giving it a dedicated __kmod_info section yields a *section* symbol ('S'),
 * which kmutil does not accept.
 *
 * THE ENTRY POINTS ARE MANGLED - THIS IS THE SUBTLE PART
 * -----------------------------------------------------
 * zutil.c defines the entry points, but it is a .c file deliberately compiled
 * as C++ (it wraps other bodies in extern "C" and includes a C++ header), and
 * the entry points themselves are NOT inside an extern "C" block. Compiling it
 * alone shows what is actually emitted:
 *
 *     $ clang++ ... -c IntelBluetoothFirmware/zutil.c -o zutil.o
 *     $ nm zutil.o | grep -i start
 *     00000000000000b0 T __Z5_stopP9kmod_infoPv
 *     00000000000000e0 T __Z6_startP9kmod_infoPv
 *
 * i.e. C++-mangled names. No plain `_start` / `__start` / `___start`
 * declaration can therefore ever resolve, and kmod_info.start stays 0, which
 * the kernel rejects with:
 *
 *     Kext com.zxystd.IntelBluetoothFirmware module start pointer is outside of
 *     kext range (start 0xffffff8000100000 - kext starts at 0xffffff8004057000)
 *     start failed (result 0xdc008007) -> failed to load (0xdc008017)
 *
 * Rather than modify upstream's zutil.c, this file calls the mangled functions
 * through their real names and exports proper C-linkage `_start` / `_stop`
 * wrappers for kmod_info to point at.
 *
 * VERIFY AFTER LINKING: kmod_info.start (offset 0x38 in the struct) must be
 * NON-ZERO, and `nm` must show `_start`/`_stop` as defined `T` symbols.
 */

#include <mach/kmod.h>

#ifndef KMOD_NAME_VALUE
#define KMOD_NAME_VALUE "com.zxystd.IntelBluetoothFirmware"
#endif

#ifndef KMOD_VERSION_VALUE
#define KMOD_VERSION_VALUE "2.6.0"
#endif

/*
 * The bridge below is only valid for a target that also links zutil.c. For a
 * target that does not (e.g. IntelBTPatcher, which gets its entry points from
 * Lilu's plugin_start.cpp), compiling it leaves __Z6_startP9kmod_infoPv and
 * __Z5_stopP9kmod_infoPv UNDEFINED - and OpenCore's prelinked injector rejects a
 * kext with unresolved symbols ("Invalid Parameter"). Define
 * IBF_NO_ZUTIL_BRIDGE for such targets.
 */
#ifndef IBF_NO_ZUTIL_BRIDGE
/* The real, C++-mangled entry points emitted by zutil.c (compiled as C++). */
extern "C" {
    int _Z5_stopP9kmod_infoPv(struct kmod_info *, void *);
    int _Z6_startP9kmod_infoPv(struct kmod_info *, void *);
}

/* C-linkage entry points for kmod_info. */
extern "C" int _start(struct kmod_info *ki, void *d) {
    return _Z6_startP9kmod_infoPv(ki, d);
}

extern "C" int _stop(struct kmod_info *ki, void *d) {
    return _Z5_stopP9kmod_infoPv(ki, d);
}
#else /* IBF_NO_ZUTIL_BRIDGE */
/*
 * Target does not link zutil.c, so there is nothing to bridge to. Its real entry
 * points are Lilu's kern_start/kern_stop from plugin_start.cpp. kmod_info still
 * requires a start/stop pair, so supply trivial ones rather than leaving
 * unresolved symbols that OpenCore's injector rejects.
 */
extern "C" int _start(struct kmod_info *, void *) {
    return KERN_SUCCESS;
}

extern "C" int _stop(struct kmod_info *, void *) {
    return KERN_SUCCESS;
}
#endif /* IBF_NO_ZUTIL_BRIDGE */

/* No section() attribute on purpose: a plain global lands in __DATA,__data. */
kmod_info_t kmod_info
    __attribute__((used, visibility("default"))) = {
        .next            = 0,
        .info_version    = KMOD_INFO_VERSION,
        .id              = 0,
        .name            = KMOD_NAME_VALUE,
        .version         = KMOD_VERSION_VALUE,
        .reference_count = 0,
        .reference_list  = 0,
        .address         = 0,
        .size            = 0,
        .hdr_size        = 0,
        .start           = &_start,
        .stop            = &_stop,
};
