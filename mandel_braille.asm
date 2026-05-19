; mandel_braille.asm - Color Braille Mandelbrot in x86-64 Linux assembly
; Uses SSE2 for floating-point math, raw syscalls for I/O, Unicode Braille
; for 2x4 subpixel resolution, and ANSI 256-color escapes for color.
;
; Assemble: nasm -f elf64 mandel_braille.asm -o mandel_braille.o
; Link:     ld mandel_braille.o -o mandel_braille
; Run:      ./mandel_braille

%define COLS        80
%define ROWS        40
%define MAX_ITER    150

section .rodata
    align 8
    ; Braille dot mask indexed by (sy*2 + sx). Unicode bit positions:
    ;   (sx=0,sy=0)->0x01   (sx=1,sy=0)->0x08
    ;   (sx=0,sy=1)->0x02   (sx=1,sy=1)->0x10
    ;   (sx=0,sy=2)->0x04   (sx=1,sy=2)->0x20
    ;   (sx=0,sy=3)->0x40   (sx=1,sy=3)->0x80
    dot_mask    db  1, 8, 2, 16, 4, 32, 64, 128

    ; 16-step ANSI 256-color gradient: deep blue -> purple -> red -> yellow
    color_table:
        db  17, 18, 19, 20, 21, 57, 93, 129
        db  165, 201, 197, 203, 208, 214, 220, 226
    color_count equ 16

    align 8
    f_xmin      dq  -2.2
    f_ymin      dq  -1.2
    f_four      dq   4.0
    f_dx        dq   0.01875     ; (xmax-xmin)/pxw = 3.0/160
    f_dy        dq   0.015       ; (ymax-ymin)/pxh = 2.4/160

section .data
    ansi_fg         db  27, "[38;5;"
    ansi_fg_len     equ $ - ansi_fg
    ansi_reset      db  27, "[0m", 10
    ansi_reset_len  equ $ - ansi_reset
    final_reset     db  27, "[0m"
    final_reset_len equ $ - final_reset

section .bss
    line_buf    resb 8192
    num_buf     resb 8

section .text
    global _start

_start:
    xor     r12, r12                ; r12 = row

.row_loop:
    cmp     r12, ROWS
    jge     .done

    lea     rbx, [rel line_buf]
    xor     r13, r13                ; r13 = col

.col_loop:
    cmp     r13, COLS
    jge     .row_end

    xor     r14, r14                ; Braille bits
    xor     r15, r15                ; iter sum
    xor     rbp, rbp                ; escaped count

    xor     ecx, ecx                ; sub-index 0..7

.sub_loop:
    cmp     ecx, 8
    jge     .sub_done

    mov     eax, ecx
    and     eax, 1                  ; sx
    mov     edx, ecx
    shr     edx, 1                  ; sy

    ; px = col*2 + sx
    mov     r8, r13
    shl     r8, 1
    add     r8, rax

    ; py = row*4 + sy
    mov     r9, r12
    shl     r9, 2
    add     r9, rdx

    ; cx = xmin + px*dx
    cvtsi2sd xmm0, r8
    mulsd   xmm0, [rel f_dx]
    addsd   xmm0, [rel f_xmin]

    ; cy = ymin + py*dy
    cvtsi2sd xmm1, r9
    mulsd   xmm1, [rel f_dy]
    addsd   xmm1, [rel f_ymin]

    ; z = 0
    xorpd   xmm2, xmm2              ; zx
    xorpd   xmm3, xmm3              ; zy

    xor     edi, edi

.iter_loop:
    movsd   xmm4, xmm2
    mulsd   xmm4, xmm2              ; zx^2
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm3              ; zy^2
    movsd   xmm6, xmm4
    addsd   xmm6, xmm5              ; |z|^2
    ucomisd xmm6, [rel f_four]
    ja      .escaped

    ; new_zy = 2*zx*zy + cy
    movsd   xmm6, xmm2
    mulsd   xmm6, xmm3
    addsd   xmm6, xmm6
    addsd   xmm6, xmm1

    ; new_zx = zx^2 - zy^2 + cx
    subsd   xmm4, xmm5
    addsd   xmm4, xmm0

    movsd   xmm2, xmm4
    movsd   xmm3, xmm6

    inc     edi
    cmp     edi, MAX_ITER
    jl      .iter_loop
    jmp     .next_sub               ; hit max -> in set

.escaped:
    lea     rax, [rel dot_mask]
    movzx   edx, byte [rax + rcx]
    or      r14, rdx
    add     r15, rdi
    inc     rbp

.next_sub:
    inc     ecx
    jmp     .sub_loop

.sub_done:
    test    rbp, rbp
    jz      .emit_blank

    ; avg iter
    mov     rax, r15
    xor     rdx, rdx
    div     rbp

    ; color index
    cmp     rax, MAX_ITER
    jl      .iter_ok
    mov     rax, MAX_ITER - 1
.iter_ok:
    mov     rdx, color_count
    mul     rdx
    mov     rcx, MAX_ITER
    xor     rdx, rdx
    div     rcx

    lea     rdx, [rel color_table]
    movzx   eax, byte [rdx + rax]

    ; "\033[38;5;"
    lea     rsi, [rel ansi_fg]
    mov     rdi, rbx
    mov     ecx, ansi_fg_len
    rep movsb
    mov     rbx, rdi

    ; decimal color code
    call    write_decimal

    mov     byte [rbx], 'm'
    inc     rbx

    ; Braille UTF-8: 0xE2, 0xA0 | (bits>>6), 0x80 | (bits & 0x3F)
    mov     byte [rbx], 0xE2
    inc     rbx
    mov     rax, r14
    shr     rax, 6
    and     al, 0x03
    or      al, 0xA0
    mov     [rbx], al
    inc     rbx
    mov     al, r14b
    and     al, 0x3F
    or      al, 0x80
    mov     [rbx], al
    inc     rbx

    jmp     .cell_done

.emit_blank:
    mov     byte [rbx], ' '
    inc     rbx

.cell_done:
    inc     r13
    jmp     .col_loop

.row_end:
    lea     rsi, [rel ansi_reset]
    mov     rdi, rbx
    mov     ecx, ansi_reset_len
    rep movsb
    mov     rbx, rdi

    lea     rsi, [rel line_buf]
    mov     rdx, rbx
    sub     rdx, rsi
    mov     rax, 1
    mov     rdi, 1
    syscall

    inc     r12
    jmp     .row_loop

.done:
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [rel final_reset]
    mov     rdx, final_reset_len
    syscall

    mov     rax, 60
    xor     rdi, rdi
    syscall

write_decimal:
    test    eax, eax
    jnz     .nonzero
    mov     byte [rbx], '0'
    inc     rbx
    ret
.nonzero:
    lea     rdi, [rel num_buf + 8]
    mov     ecx, 10
.div_loop:
    xor     edx, edx
    div     ecx
    dec     rdi
    add     dl, '0'
    mov     [rdi], dl
    test    eax, eax
    jnz     .div_loop
    lea     rsi, [rel num_buf + 8]
.copy_loop:
    cmp     rdi, rsi
    jge     .copy_done
    mov     al, [rdi]
    mov     [rbx], al
    inc     rbx
    inc     rdi
    jmp     .copy_loop
.copy_done:
    ret
