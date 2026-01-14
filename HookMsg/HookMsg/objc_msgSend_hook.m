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
"stp q6, q7, [sp, #-32]! \n" \
"stp q4, q5, [sp, #-32]! \n" \
"stp q2, q3, [sp, #-32]! \n" \
"stp q0, q1, [sp, #-32]! \n" \
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
"ldp x8, x9, [sp], #16 \n" \
"ldp q0, q1, [sp], #32 \n" \
"ldp q2, q3, [sp], #32 \n" \
"ldp q4, q5, [sp], #32 \n" \
"ldp q6, q7, [sp], #32 \n");

__unused static id (*orig_objc_msgSend)(id, SEL, ...);

// 线程局部栈保存 LR，避免多线程时错乱
static __thread uintptr_t lr_stack[1024];
static __thread int lr_top = 0;
// 防止递归调用的标志
static __thread bool is_hooking = false;

static void pre_objc_msgSend(id self, SEL _cmd, uintptr_t lr) {
    if (is_hooking) return;
    is_hooking = true;
    
    // 压栈保存 LR
    if (lr_top < (int)(sizeof(lr_stack) / sizeof(lr_stack[0]))) {
        lr_stack[lr_top++] = lr;
    }
    // 打印类名和选择子（避免直接打印 SEL）
    const char *cls = object_getClassName(self);
    const char *sel = sel_getName(_cmd);
    printf("pre action... [%s %s]\n", cls ? cls : "(nil)", sel ? sel : "(null)");
    
    is_hooking = false;
}

static uintptr_t post_objc_msgSend(void) {
    if (is_hooking) {
        // 如果发生递归（理论上 post 不应该触发 pre 的锁，但为了安全）
        if (lr_top > 0) return lr_stack[lr_top-1];
        return 0;
    }
    is_hooking = true;
    
    printf("post action...\n");
    uintptr_t lr = 0;
    if (lr_top > 0) {
        lr_top--;
        lr = lr_stack[lr_top];
    }
    
    is_hooking = false;
    return lr;
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

#pragma mark - hook objc_alloc

__unused static id (*orig_objc_alloc)(Class);

static id hook_objc_alloc(Class cls) {
    printf("allocating class: %s\n", class_getName(cls));
    return orig_objc_alloc(cls);
}

void hookStart(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct rebinding bind_msgSend = { "objc_msgSend", (void *)hook_Objc_msgSend, (void **)&orig_objc_msgSend };
        struct rebinding bind_alloc = { "objc_alloc", (void *)hook_objc_alloc, (void **)&orig_objc_alloc };
        
        struct rebinding rebindings[] = { bind_msgSend, bind_alloc };
        rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
    });
}

#else // 非 arm64 平台

void hookStart(void) {
    printf("hookStart: unsupported architecture for objc_msgSend hook.\n");
}

#endif
