; RUN: opt -S -early-cse < %s | FileCheck %s
; RUN: opt -S -gvn < %s | FileCheck %s
; RUN: opt -S -newgvn < %s | FileCheck %s
; RUN: opt -S -O3 < %s | FileCheck %s

; These tests checks if passes with CSE functionality can do CSE on
; invariant.group.barrier, that is prohibited if there is a memory clobber
; between barriers call.

; CHECK-LABEL: define i8 @optimizable()
define i8 @optimizable() {
entry:
    %ptr = alloca i8
    store i8 42, i8* %ptr, !invariant.group !0
; CHECK: call i8* @llvm.invariant.group.barrier.p0i8
    %ptr2 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
; FIXME: This one could be CSE
; CHECK: call i8* @llvm.invariant.group.barrier
    %ptr3 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
; CHECK: call void @clobber(i8* {{.*}}%ptr)
    call void @clobber(i8* %ptr)

; CHECK: call void @use(i8* {{.*}}%ptr2)
    call void @use(i8* %ptr2)
; CHECK: call void @use(i8* {{.*}}%ptr3)
    call void @use(i8* %ptr3)
; CHECK: load i8, i8* %ptr3, {{.*}}!invariant.group
    %v = load i8, i8* %ptr3, !invariant.group !0

    ret i8 %v
}

; CHECK-LABEL: define i8 @unoptimizable()
define i8 @unoptimizable() {
entry:
    %ptr = alloca i8
    store i8 42, i8* %ptr, !invariant.group !0
; CHECK: call i8* @llvm.invariant.group.barrier.p0i8
    %ptr2 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
    call void @clobber(i8* %ptr)
; CHECK: call i8* @llvm.invariant.group.barrier.p0i8
    %ptr3 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
; CHECK: call void @clobber(i8* {{.*}}%ptr)
    call void @clobber(i8* %ptr)
; CHECK: call void @use(i8* {{.*}}%ptr2)
    call void @use(i8* %ptr2)
; CHECK: call void @use(i8* {{.*}}%ptr3)
    call void @use(i8* %ptr3)
; CHECK: load i8, i8* %ptr3, {{.*}}!invariant.group
    %v = load i8, i8* %ptr3, !invariant.group !0

    ret i8 %v
}

; CHECK-LABEL: define i8 @unoptimizable2()
define i8 @unoptimizable2() {
    %ptr = alloca i8
    store i8 42, i8* %ptr, !invariant.group !0
; CHECK: call i8* @llvm.invariant.group.barrier
    %ptr2 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
    store i8 43, i8* %ptr
; CHECK: call i8* @llvm.invariant.group.barrier
    %ptr3 = call i8* @llvm.invariant.group.barrier.p0i8(i8* %ptr)
; CHECK: call void @clobber(i8* {{.*}}%ptr)
    call void @clobber(i8* %ptr)
; CHECK: call void @use(i8* {{.*}}%ptr2)
    call void @use(i8* %ptr2)
; CHECK: call void @use(i8* {{.*}}%ptr3)
    call void @use(i8* %ptr3)
; CHECK: load i8, i8* %ptr3, {{.*}}!invariant.group
    %v = load i8, i8* %ptr3, !invariant.group !0
    ret i8 %v
}

declare void @use(i8* readonly)

declare void @clobber(i8*)
; CHECK: Function Attrs: inaccessiblememonly nounwind{{$}}
; CHECK-NEXT: declare i8* @llvm.invariant.group.barrier.p0i8(i8*)
declare i8* @llvm.invariant.group.barrier.p0i8(i8*)

!0 = !{}

