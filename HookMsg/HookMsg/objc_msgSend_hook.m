#import "objc_msgSend_hook.h"
#import "fishhook.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdint.h>

#if defined(__arm64__)

#define call(value) \
__asm__ volatile ("stp x8, x9, [sp, #-16]! \n"); \
__asm__ volatile ("mov x12, %0\n" :: "r"(value)); \
__asm__ volatile ("ldp x8, x9, [sp], #16\n"); \
__asm__ volatile ("blr x12\n");

#define save() \
__asm__ volatile ( \
"stp x8, x9, [sp, #-16]! \n" \
"stp x6, x7, [sp, #-16]! \n" \
"stp x4, x5, [sp, #-16]! \n" \
"stp x2, x3, [sp, #-16]! \n" \
"stp x0, x1, [sp, #-16]! \n");

#define load() \
__asm__ volatile ( \
"ldp x0, x1, [sp], #16 \n" \
"ldp x2, x3, [sp], #16 \n" \
"ldp x4, x5, [sp], #16 \n" \
"ldp x6, x7, [sp], #16 \n" \
"ldp x8, x9, [sp], #16 \n");

__unused static id (*orig_objc_msgSend)(id, SEL, ...);

// 线程局部栈保存 LR，避免多线程时错乱
static __thread uintptr_t lr_stack[1024];
static __thread int lr_top = 0;

static void pre_objc_msgSend(id self, SEL _cmd, uintptr_t lr) {
    // 压栈保存 LR
    if (lr_top < (int)(sizeof(lr_stack) / sizeof(lr_stack[0]))) {
        lr_stack[lr_top++] = lr;
    }
    // 打印类名和选择子（避免直接打印 SEL）
    const char *cls = object_getClassName(self);
    const char *sel = sel_getName(_cmd);
    printf("pre action... [%s %s]\n", cls ? cls : "(nil)", sel ? sel : "(null)");
}

static uintptr_t post_objc_msgSend(void) {
    printf("post action...\n");
    if (lr_top > 0) {
        lr_top--;
    }
    return lr_stack[lr_top];
}

__attribute__((naked))
static void hook_Objc_msgSend(void) {
#if defined(__arm64e__)
    // 对 arm64e 可选的 BTI 提示（避免间接跳转保护导致崩溃）
    __asm__ volatile ("bti c");
#endif
    // 保存调用方上下文
    save()

    // 将 LR 传入 x2 作为 pre_objc_msgSend 的第三个参数
    __asm__ volatile ("mov x2, lr \n");

    // 调用 pre 钩子
    call(&pre_objc_msgSend)

    // 还原上下文
    load()

    // 调用原始 objc_msgSend
    call(orig_objc_msgSend)

    // 保存返回值和寄存器
    save()

    // 调用 post 钩子，返回原始 LR 于 x0
    call(&post_objc_msgSend)

    // 用 post 返回的值恢复 LR
    __asm__ volatile ("mov lr, x0 \n");

    // 还原上下文（包括把原始返回值恢复到 x0）
    load()

    // 返回到原始调用点
    __asm__ volatile ("ret \n");
}

void hookStart(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct rebinding bind = { "objc_msgSend", (void *)hook_Objc_msgSend, (void **)&orig_objc_msgSend };
        rebind_symbols(&bind, 1);
    });
}

#else // 非 arm64 平台

void hookStart(void) {
    printf("hookStart: unsupported architecture for objc_msgSend hook.\n");
}

#endif