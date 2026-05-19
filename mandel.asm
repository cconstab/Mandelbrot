; mandel.asm - ASCII Mandelbrot set in x86-64 Linux assembly
; Uses x87 FPU for floating-point math, raw syscalls for I/O.
;
; Assemble: nasm -f elf64 mandel.asm -o mandel.o
; Link:     ld mandel.o -o mandel
; Run:      ./mandel

section .data
    ; Characters used to render brightness, from "deep in set" to "escaped fast".
    ; Index = iterations until escape, capped at MAX_ITER.
    palette     db  " .,:;i1tfLCG08@", 0
    palette_len equ $ - palette - 1     ; 15 chars (excluding null)

    newline     db  10

    ; Floating-point constants (doubles, 8 bytes each)
    f_xmin      dq  -2.5
    f_xmax      dq   1.0
    f_ymin      dq  -1.1
    f_ymax      dq   1.1
    f_four      dq   4.0
    f_width     dq   80.0
    f_height    dq   30.0

section .bss
    line_buf    resb 128                 ; output buffer for one line

section .text
    global _start

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------
%define WIDTH       80
%define HEIGHT      30
%define MAX_ITER    100

_start:
    ; -------- outer loop: py = 0 .. HEIGHT-1 --------
    xor     r12, r12                    ; r12 = py

.row_loop:
    cmp     r12, HEIGHT
    jge     .done

    ; cy = ymin + (ymax - ymin) * py / height
    fld     qword [f_ymax]
    fsub    qword [f_ymin]              ; st0 = ymax - ymin
    mov     [rsp-8], r12
    fild    qword [rsp-8]               ; st0 = py, st1 = (ymax-ymin)
    fmulp   st1, st0                    ; st0 = (ymax-ymin)*py
    fdiv    qword [f_height]            ; st0 = (ymax-ymin)*py / height
    fadd    qword [f_ymin]              ; st0 = cy
    ; keep cy on FPU stack throughout the row

    xor     r13, r13                    ; r13 = px

.col_loop:
    cmp     r13, WIDTH
    jge     .row_end

    ; cx = xmin + (xmax - xmin) * px / width
    fld     qword [f_xmax]
    fsub    qword [f_xmin]
    mov     [rsp-8], r13
    fild    qword [rsp-8]
    fmulp   st1, st0
    fdiv    qword [f_width]
    fadd    qword [f_xmin]              ; st0 = cx, st1 = cy

    ; -------- iteration: z = z^2 + c --------
    ; FPU stack layout after setup: st0=zy, st1=zx, st2=cx, st3=cy
    fldz                                ; zy = 0     st0=zy, st1=cx, st2=cy
    fldz                                ; zx = 0     st0=zx, st1=zy, st2=cx, st3=cy
    ; reorder so it's zy, zx, cx, cy
    fxch    st1                         ; st0=zy, st1=zx, st2=cx, st3=cy

    xor     ecx, ecx                    ; iter = 0

.iter_loop:
    ; Compute zx^2 and zy^2 (without losing zx, zy)
    ; st: zy, zx, cx, cy
    fld     st1                         ; st0=zx, st1=zy, st2=zx, st3=cx, st4=cy
    fmul    st0, st0                    ; st0=zx^2
    fld     st1                         ; st0=zy, st1=zx^2, st2=zy, st3=zx, st4=cx, st5=cy
    fmul    st0, st0                    ; st0=zy^2
    ; magnitude check: zx^2 + zy^2 > 4 ?
    fld     st0                         ; duplicate zy^2
    fadd    st0, st2                    ; st0 = zx^2 + zy^2 (st2 is zx^2)
    fcomp   qword [f_four]              ; compare and pop
    fnstsw  ax
    sahf
    ja      .escaped                    ; if > 4, bail

    ; Still bounded. Update z:
    ; new_zx = zx^2 - zy^2 + cx
    ; new_zy = 2*zx*zy + cy
    ;
    ; Current stack: st0=zy^2, st1=zx^2, st2=zy, st3=zx, st4=cx, st5=cy
    ;
    ; First compute new_zy = 2*zx*zy + cy
    fld     st3                         ; zx           -> st0=zx, st1=zy^2, st2=zx^2, st3=zy, st4=zx, st5=cx, st6=cy
    fmul    st0, st3                    ; zx*zy        (st3 is zy)
    fadd    st0, st0                    ; 2*zx*zy
    fadd    st0, st6                    ; 2*zx*zy + cy = new_zy
    ; stack: st0=new_zy, st1=zy^2, st2=zx^2, st3=zy, st4=zx, st5=cx, st6=cy

    ; Now compute new_zx = zx^2 - zy^2 + cx
    fld     st2                         ; zx^2         -> st0=zx^2, st1=new_zy, st2=zy^2, st3=zx^2_old, st4=zy, st5=zx, st6=cx, st7=cy
    fsub    st0, st2                    ; zx^2 - zy^2
    fadd    st0, st6                    ; + cx = new_zx
    ; stack: st0=new_zx, st1=new_zy, st2=zy^2, st3=zx^2, st4=zy, st5=zx, st6=cx, st7=cy

    ; We need to keep only: new_zy, new_zx, cx, cy
    ; Swap new_zx with old zx (st5), then drop the intermediates
    fstp    st5                         ; pop new_zx into st5 (replacing old zx)
    ; stack: st0=new_zy, st1=zy^2, st2=zx^2, st3=zy, st4=new_zx, st5=cx, st6=cy
    fstp    st3                         ; pop new_zy into st3 (replacing old zy)
    ; stack: st0=zy^2, st1=zx^2, st2=new_zy, st3=new_zx, st4=cx, st5=cy
    fstp    st0                         ; drop zy^2
    fstp    st0                         ; drop zx^2
    ; stack: st0=new_zy, st1=new_zx, st2=cx, st3=cy   -- back to (zy, zx, cx, cy)

    inc     ecx
    cmp     ecx, MAX_ITER
    jl      .iter_loop

    ; Hit max iterations -> point is in the set, ecx = MAX_ITER
    jmp     .pick_char

.escaped:
    ; After fcomp (which pops one), stack is:
    ;   st0=zy^2, st1=zx^2, st2=zy, st3=zx, st4=cx, st5=cy
    ; Drop all 6.
    fstp    st0                         ; drop zy^2
    fstp    st0                         ; drop zx^2
    fstp    st0                         ; drop zy
    fstp    st0                         ; drop zx
    fstp    st0                         ; drop cx
    fstp    st0                         ; drop cy
    jmp     .after_clean

.pick_char:
    ; In the set: clean up. Stack: zy, zx, cx, cy
    fstp    st0
    fstp    st0
    fstp    st0
    fstp    st0

.after_clean:
    ; Map ecx (0..MAX_ITER) to a palette character.
    ; In-set points (ecx == MAX_ITER) get the first char (space).
    cmp     ecx, MAX_ITER
    jge     .in_set
    ; idx = ecx * palette_len / MAX_ITER, then offset into palette (skip space)
    mov     eax, ecx
    mov     edx, palette_len - 1
    mul     edx                          ; eax = ecx * (palette_len - 1)
    mov     ebx, MAX_ITER
    xor     edx, edx
    div     ebx                          ; eax = idx in [0, palette_len-1)
    inc     eax                          ; skip the leading space, use [1..palette_len-1]
    mov     bl, [palette + rax]
    jmp     .store_char
.in_set:
    mov     bl, ' '                      ; in-set -> blank

.store_char:
    mov     [line_buf + r13], bl

    inc     r13
    ; We popped the row's cy at the start of the column setup? No - we still have cy on stack.
    ; Actually cy was loaded ONCE before the col_loop and we need to restore it for next iteration.
    ; Re-load cy for the next column:
    fld     qword [f_ymax]
    fsub    qword [f_ymin]
    mov     [rsp-8], r12
    fild    qword [rsp-8]
    fmulp   st1, st0
    fdiv    qword [f_height]
    fadd    qword [f_ymin]
    jmp     .col_loop

.row_end:
    ; (cy is no longer on the stack at this point because we cleaned at .after_clean)
    ; Append newline and write the line
    mov     byte [line_buf + WIDTH], 10
    mov     rax, 1                       ; sys_write
    mov     rdi, 1                       ; stdout
    mov     rsi, line_buf
    mov     rdx, WIDTH + 1
    syscall

    inc     r12
    jmp     .row_loop

.done:
    mov     rax, 60                      ; sys_exit
    xor     rdi, rdi
    syscall
