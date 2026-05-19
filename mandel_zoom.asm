; mandel_zoom.asm - Interactive Braille Mandelbrot in x86-64 Linux assembly
;
; Controls:
;   w/a/s/d   pan up/left/down/right
;   + / =     zoom in
;   - / _     zoom out
;   r         reset view
;   i / k     decrease/increase max iterations
;   q / ESC   quit
;
; Assemble: nasm -f elf64 mandel_zoom.asm -o mandel_zoom.o
; Link:     ld mandel_zoom.o -o mandel_zoom
; Run:      ./mandel_zoom

; Maximum sizes (used for buffer allocation only). Actual size at runtime
; is queried from the terminal via TIOCGWINSZ and may be smaller.
%define MAX_COLS    400
%define MAX_ROWS    200

; Reserve the bottom 2 lines for the status display (info + controls).
%define STATUS_ROWS 2

; --- Linux syscall numbers ---
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_IOCTL       16
%define SYS_RT_SIGACTION 13
%define SYS_EXIT        60

; --- termios / ioctl ---
%define TCGETS          0x5401
%define TCSETS          0x5402
%define TIOCGWINSZ      0x5413
%define ICANON          2
%define ECHO            8
%define VMIN_OFFSET     6           ; offset of c_cc[VMIN] in termios
%define VTIME_OFFSET    5           ; offset of c_cc[VTIME] in termios

; --- Signals ---
%define SIGWINCH        28
%define SIGINT          2
%define SIGTERM         15

section .rodata
    align 8
    dot_mask    db  1, 8, 2, 16, 4, 32, 64, 128

    color_table:
        db  17, 18, 19, 20, 21, 57, 93, 129
        db  165, 201, 197, 203, 208, 214, 220, 226
    color_count equ 16

    align 8
    f_four      dq   4.0
    f_two       dq   2.0
    f_zoom_in   dq   0.7           ; zoom-in factor
    f_zoom_out  dq   1.4285714285714286 ; 1/0.7
    f_pan_frac  dq   0.15          ; pan = 15% of current view per keypress

    ; Initial view
    f_init_cx   dq  -0.7
    f_init_cy   dq   0.0
    f_init_scale dq  1.5           ; half-height of view

    ; Cursor home: ESC [ H
    cursor_home db  27, "[H"
    cursor_home_len equ $ - cursor_home

    ; Clear screen + home: ESC [ 2 J ESC [ H
    clear_screen db  27, "[2J", 27, "[H"
    clear_screen_len equ $ - clear_screen

    ; Hide / show cursor
    hide_cursor db  27, "[?25l"
    hide_cursor_len equ $ - hide_cursor
    show_cursor db  27, "[?25h"
    show_cursor_len equ $ - show_cursor

    ansi_fg     db  27, "[38;5;"
    ansi_fg_len equ $ - ansi_fg
    ansi_reset_nl db 27, "[0m", 10
    ansi_reset_nl_len equ $ - ansi_reset_nl
    final_reset db  27, "[0m"
    final_reset_len equ $ - final_reset

    ; Status line (printed below the image)
    status_pre  db  27, "[0m", "  center=("
    status_pre_len equ $ - status_pre
    status_mid1 db  ", "
    status_mid1_len equ $ - status_mid1
    status_mid2 db  ")  scale="
    status_mid2_len equ $ - status_mid2
    status_mid3 db  "  iter="
    status_mid3_len equ $ - status_mid3
    ; End of status line 1: clear-to-EOL + newline
    status_eol1 db  27, "[K", 10
    status_eol1_len equ $ - status_eol1
    ; Status line 2: controls help
    status_help db  "  [wasd] pan  [+/-] zoom  [i/k] iter  [r] reset  [q] quit", 27, "[K", 10
    status_help_len equ $ - status_help

    ; ESC [ K = erase to end of line (so old text doesn't bleed through)
    clear_eol   db  27, "[K"
    clear_eol_len equ $ - clear_eol

section .data
    ; Current view (mutable)
    cur_cx      dq  -0.7
    cur_cy      dq   0.0
    cur_scale   dq   1.5           ; half-height; half-width is scale*aspect
    cur_iter    dq   100

    ; Aspect ratio of the rendered region (px_w / px_h, as a double).
    ; Set in update_dimensions based on the current terminal size.
    f_aspect    dq   1.0

    ; Terminal dimensions (queried at startup and on SIGWINCH).
    ; cur_cols/cur_rows are in CHARACTER cells (after subtracting STATUS_ROWS
    ; from the raw window height). px_w/px_h are subpixel resolution.
    cur_cols    dq  80
    cur_rows    dq  40
    cur_px_w    dq  160
    cur_px_h    dq  160

    ; Set by SIGWINCH handler; checked at top of main loop.
    resize_pending db 0

    ; Saved termios (for restoration)
    saved_termios times 60 db 0
    new_termios   times 60 db 0

    ; winsize struct for TIOCGWINSZ:
    ;   unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel
    winsize     dw  0, 0, 0, 0

section .bss
    line_buf    resb 262144       ; large enough for ~400-col color Braille rows
    num_buf     resb 32
    key_buf     resb 8

section .text
    global _start

; ===========================================================================
_start:
    ; Install signal handlers (SIGINT, SIGTERM, SIGWINCH) before anything else
    ; so we restore the terminal even if signaled early.
    call    install_signal_handlers

    ; Query terminal size for initial render
    call    update_dimensions

    ; Switch terminal to raw mode (no echo, no line buffering)
    call    enable_raw_mode

    ; Hide cursor and clear screen once
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel hide_cursor]
    mov     rdx, hide_cursor_len
    syscall

    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel clear_screen]
    mov     rdx, clear_screen_len
    syscall

.main_loop:
    ; If terminal was resized, re-query and full-clear the screen.
    cmp     byte [rel resize_pending], 0
    je      .no_resize
    mov     byte [rel resize_pending], 0
    call    update_dimensions
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel clear_screen]
    mov     rdx, clear_screen_len
    syscall
.no_resize:
    ; Move cursor to home, render frame
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel cursor_home]
    mov     rdx, cursor_home_len
    syscall

    call    render_frame
    call    render_status

    ; Read one keypress (blocking)
    mov     rax, SYS_READ
    mov     rdi, 0
    lea     rsi, [rel key_buf]
    mov     rdx, 1
    syscall
    test    rax, rax
    jz      .quit                   ; EOF -> clean quit
    js      .read_interrupted       ; <0 (e.g. EINTR from SIGWINCH)

    movzx   eax, byte [rel key_buf]

    cmp     al, 'q'
    je      .quit
    cmp     al, 27                  ; ESC
    je      .quit

    cmp     al, 'w'
    je      .pan_up
    cmp     al, 's'
    je      .pan_down
    cmp     al, 'a'
    je      .pan_left
    cmp     al, 'd'
    je      .pan_right

    cmp     al, '+'
    je      .zoom_in
    cmp     al, '='
    je      .zoom_in
    cmp     al, '-'
    je      .zoom_out
    cmp     al, '_'
    je      .zoom_out

    cmp     al, 'r'
    je      .reset

    cmp     al, 'i'
    je      .iter_down
    cmp     al, 'k'
    je      .iter_up

    jmp     .main_loop

.read_interrupted:
    ; read() was interrupted by a signal (probably SIGWINCH). Loop back; the
    ; main_loop's resize check will handle any pending resize.
    jmp     .main_loop

.pan_up:
    ; cy -= scale * pan_frac
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_pan_frac]
    movsd   xmm1, [rel cur_cy]
    subsd   xmm1, xmm0
    movsd   [rel cur_cy], xmm1
    jmp     .main_loop

.pan_down:
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_pan_frac]
    movsd   xmm1, [rel cur_cy]
    addsd   xmm1, xmm0
    movsd   [rel cur_cy], xmm1
    jmp     .main_loop

.pan_left:
    ; cx -= scale * aspect * pan_frac
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_aspect]
    mulsd   xmm0, [rel f_pan_frac]
    movsd   xmm1, [rel cur_cx]
    subsd   xmm1, xmm0
    movsd   [rel cur_cx], xmm1
    jmp     .main_loop

.pan_right:
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_aspect]
    mulsd   xmm0, [rel f_pan_frac]
    movsd   xmm1, [rel cur_cx]
    addsd   xmm1, xmm0
    movsd   [rel cur_cx], xmm1
    jmp     .main_loop

.zoom_in:
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_zoom_in]
    movsd   [rel cur_scale], xmm0
    ; Auto-bump iterations as we zoom in
    mov     rax, [rel cur_iter]
    add     rax, 20
    cmp     rax, 2000
    jle     .zi_ok
    mov     rax, 2000
.zi_ok:
    mov     [rel cur_iter], rax
    jmp     .main_loop

.zoom_out:
    movsd   xmm0, [rel cur_scale]
    mulsd   xmm0, [rel f_zoom_out]
    movsd   [rel cur_scale], xmm0
    jmp     .main_loop

.reset:
    movsd   xmm0, [rel f_init_cx]
    movsd   [rel cur_cx], xmm0
    movsd   xmm0, [rel f_init_cy]
    movsd   [rel cur_cy], xmm0
    movsd   xmm0, [rel f_init_scale]
    movsd   [rel cur_scale], xmm0
    mov     qword [rel cur_iter], 100
    ; Full clear in case status line gets confused
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel clear_screen]
    mov     rdx, clear_screen_len
    syscall
    jmp     .main_loop

.iter_up:
    mov     rax, [rel cur_iter]
    add     rax, 50
    cmp     rax, 5000
    jle     .iu_ok
    mov     rax, 5000
.iu_ok:
    mov     [rel cur_iter], rax
    jmp     .main_loop

.iter_down:
    mov     rax, [rel cur_iter]
    sub     rax, 50
    cmp     rax, 30
    jge     .id_ok
    mov     rax, 30
.id_ok:
    mov     [rel cur_iter], rax
    jmp     .main_loop

.quit:
    call    cleanup_and_exit

; ===========================================================================
; render_frame: render the current Mandelbrot view to stdout
; ===========================================================================
render_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    ; Compute step sizes: dx = 2*scale*aspect / PX_W ; dy = 2*scale / PX_H
    ; And origin: xmin = cx - scale*aspect ; ymin = cy - scale
    movsd   xmm10, [rel cur_scale]
    movsd   xmm11, xmm10
    mulsd   xmm11, [rel f_aspect]   ; xmm11 = scale*aspect
    ; xmin = cx - scale*aspect
    movsd   xmm12, [rel cur_cx]
    subsd   xmm12, xmm11            ; xmm12 = xmin
    ; ymin = cy - scale
    movsd   xmm13, [rel cur_cy]
    subsd   xmm13, xmm10            ; xmm13 = ymin
    ; dx = 2*scale*aspect / cur_px_w
    addsd   xmm11, xmm11            ; 2*scale*aspect
    mov     rax, [rel cur_px_w]
    cvtsi2sd xmm14, rax
    divsd   xmm11, xmm14            ; xmm11 = dx
    ; dy = 2*scale / cur_px_h
    movsd   xmm14, xmm10
    addsd   xmm14, xmm14            ; 2*scale
    mov     rax, [rel cur_px_h]
    cvtsi2sd xmm15, rax
    divsd   xmm14, xmm15            ; xmm14 = dy
    ; Now: xmm11=dx, xmm12=xmin, xmm13=ymin, xmm14=dy

    xor     r12, r12                ; row
.row:
    cmp     r12, [rel cur_rows]
    jge     .done

    lea     rbx, [rel line_buf]     ; write pointer
    xor     r13, r13                ; col

.col:
    cmp     r13, [rel cur_cols]
    jge     .row_end

    xor     r14, r14                ; Braille bits
    xor     r15, r15                ; iter sum
    xor     rbp, rbp                ; escaped count

    xor     ecx, ecx                ; sub-index 0..7

.sub:
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

    ; cx_pt = xmin + px * dx
    cvtsi2sd xmm0, r8
    mulsd   xmm0, xmm11
    addsd   xmm0, xmm12             ; xmm0 = cx_pt
    ; cy_pt = ymin + py * dy
    cvtsi2sd xmm1, r9
    mulsd   xmm1, xmm14
    addsd   xmm1, xmm13             ; xmm1 = cy_pt

    ; z = 0
    xorpd   xmm2, xmm2              ; zx
    xorpd   xmm3, xmm3              ; zy

    xor     edi, edi
    mov     r10, [rel cur_iter]

.iter:
    movsd   xmm4, xmm2
    mulsd   xmm4, xmm2              ; zx^2
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm3              ; zy^2
    movsd   xmm6, xmm4
    addsd   xmm6, xmm5
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
    cmp     rdi, r10
    jl      .iter
    jmp     .next_sub               ; in set

.escaped:
    lea     rax, [rel dot_mask]
    movzx   edx, byte [rax + rcx]
    or      r14, rdx
    add     r15, rdi
    inc     rbp

.next_sub:
    inc     ecx
    jmp     .sub

.sub_done:
    test    rbp, rbp
    jz      .blank

    ; avg = r15 / rbp
    mov     rax, r15
    xor     rdx, rdx
    div     rbp

    ; color_idx = avg * color_count / cur_iter
    mov     rcx, [rel cur_iter]
    cmp     rax, rcx
    jl      .iok
    lea     rax, [rcx - 1]
.iok:
    mov     rdx, color_count
    mul     rdx
    xor     rdx, rdx
    div     rcx                     ; rax = color idx

    lea     rdx, [rel color_table]
    movzx   eax, byte [rdx + rax]

    ; "\033[38;5;"
    lea     rsi, [rel ansi_fg]
    mov     rdi, rbx
    mov     ecx, ansi_fg_len
    rep movsb
    mov     rbx, rdi

    call    write_decimal_u32

    mov     byte [rbx], 'm'
    inc     rbx

    ; UTF-8 Braille
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

.blank:
    mov     byte [rbx], ' '
    inc     rbx

.cell_done:
    inc     r13
    jmp     .col

.row_end:
    ; Reset + clear-to-end-of-line + newline
    lea     rsi, [rel ansi_reset_nl]
    mov     rdi, rbx
    sub     rdi, 1                  ; we'll insert clear_eol before \n
    ; Simpler: emit clear_eol then reset+nl
    mov     rdi, rbx
    lea     rsi, [rel clear_eol]
    mov     ecx, clear_eol_len
    rep movsb
    mov     rbx, rdi
    lea     rsi, [rel ansi_reset_nl]
    mov     rdi, rbx
    mov     ecx, ansi_reset_nl_len
    rep movsb
    mov     rbx, rdi

    ; Write line
    lea     rsi, [rel line_buf]
    mov     rdx, rbx
    sub     rdx, rsi
    mov     rax, SYS_WRITE
    mov     rdi, 1
    syscall

    inc     r12
    jmp     .row

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ===========================================================================
; render_status: print the status line below the image
; ===========================================================================
render_status:
    push    rbx

    lea     rbx, [rel line_buf]

    ; "  center=("
    lea     rsi, [rel status_pre]
    mov     rdi, rbx
    mov     ecx, status_pre_len
    rep movsb
    mov     rbx, rdi

    ; cx
    movsd   xmm0, [rel cur_cx]
    call    write_double_v2

    ; ", "
    lea     rsi, [rel status_mid1]
    mov     rdi, rbx
    mov     ecx, status_mid1_len
    rep movsb
    mov     rbx, rdi

    ; cy
    movsd   xmm0, [rel cur_cy]
    call    write_double_v2

    ; ")  scale="
    lea     rsi, [rel status_mid2]
    mov     rdi, rbx
    mov     ecx, status_mid2_len
    rep movsb
    mov     rbx, rdi

    ; scale
    movsd   xmm0, [rel cur_scale]
    call    write_double_v2

    ; "  iter="
    lea     rsi, [rel status_mid3]
    mov     rdi, rbx
    mov     ecx, status_mid3_len
    rep movsb
    mov     rbx, rdi

    ; iter
    mov     eax, [rel cur_iter]
    call    write_decimal_u32

    ; End status line 1 (clear-to-EOL + newline)
    lea     rsi, [rel status_eol1]
    mov     rdi, rbx
    mov     ecx, status_eol1_len
    rep movsb
    mov     rbx, rdi

    ; help text + clear-eol + newline
    lea     rsi, [rel status_help]
    mov     rdi, rbx
    mov     ecx, status_help_len
    rep movsb
    mov     rbx, rdi

    ; Write the whole thing
    lea     rsi, [rel line_buf]
    mov     rdx, rbx
    sub     rdx, rsi
    mov     rax, SYS_WRITE
    mov     rdi, 1
    syscall

    pop     rbx
    ret

; ===========================================================================
; write_decimal_u32: write eax as decimal to [rbx], advance rbx
; ===========================================================================
write_decimal_u32:
    push    rbx
    push    rdi
    push    rsi
    push    rcx
    push    rdx

    test    eax, eax
    jnz     .nonzero
    mov     byte [rbx], '0'
    inc     rbx
    jmp     .done

.nonzero:
    test    eax, eax
    jns     .pos
    neg     eax
    mov     byte [rbx], '-'
    inc     rbx
.pos:
    lea     rdi, [rel num_buf + 16]
    mov     ecx, 10
.dl:
    xor     edx, edx
    div     ecx
    dec     rdi
    add     dl, '0'
    mov     [rdi], dl
    test    eax, eax
    jnz     .dl

    lea     rsi, [rel num_buf + 16]
.cl:
    cmp     rdi, rsi
    jge     .done
    mov     al, [rdi]
    mov     [rbx], al
    inc     rbx
    inc     rdi
    jmp     .cl

.done:
    ; rbx is what we want to return; we pushed it earlier so we need to
    ; preserve the new value through the pops.
    mov     rax, rbx                ; save new rbx
    pop     rdx
    pop     rcx
    pop     rsi
    pop     rdi
    pop     rbx                     ; restore old rbx (discard)
    mov     rbx, rax                ; install new value
    ret

; ===========================================================================
; write_double_v2: write xmm0 to [rbx] with 7 decimal places, advances rbx
; ===========================================================================
write_double_v2:
    push    rax
    push    rcx
    push    rdx
    push    r8
    push    r9

    ; Handle sign
    xorps   xmm7, xmm7
    ucomisd xmm0, xmm7
    jae     .nonneg
    mov     byte [rbx], '-'
    inc     rbx
    movsd   xmm1, xmm7
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
.nonneg:
    ; Integer part
    cvttsd2si rax, xmm0
    mov     r8, rax                 ; save int part
    call    write_decimal_u32
    cvtsi2sd xmm1, r8
    subsd   xmm0, xmm1              ; fractional

    mov     byte [rbx], '.'
    inc     rbx

    ; Emit 7 fractional digits
    mov     r9d, 7
.fl:
    test    r9d, r9d
    jz      .done
    mov     eax, 10
    cvtsi2sd xmm1, eax
    mulsd   xmm0, xmm1
    cvttsd2si eax, xmm0
    cvtsi2sd xmm1, eax
    subsd   xmm0, xmm1
    add     al, '0'
    mov     [rbx], al
    inc     rbx
    dec     r9d
    jmp     .fl
.done:
    pop     r9
    pop     r8
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ===========================================================================
; enable_raw_mode: switch terminal to non-canonical, no-echo mode.
; Saves original termios to saved_termios.
; ===========================================================================
enable_raw_mode:
    ; ioctl(0, TCGETS, &saved_termios)
    mov     rax, SYS_IOCTL
    mov     rdi, 0
    mov     rsi, TCGETS
    lea     rdx, [rel saved_termios]
    syscall

    ; Copy saved -> new
    lea     rsi, [rel saved_termios]
    lea     rdi, [rel new_termios]
    mov     ecx, 60
    rep movsb

    ; Clear ICANON and ECHO in c_lflag (offset 12 in linux termios)
    mov     eax, [rel new_termios + 12]
    and     eax, ~(ICANON | ECHO)
    mov     [rel new_termios + 12], eax

    ; Set VMIN=1, VTIME=0 (offsets into c_cc array; c_cc starts at offset 17)
    ; Linux termios c_cc[VMIN] is at offset 17+6=23, c_cc[VTIME] at 17+5=22
    mov     byte [rel new_termios + 17 + VMIN_OFFSET], 1
    mov     byte [rel new_termios + 17 + VTIME_OFFSET], 0

    ; ioctl(0, TCSETS, &new_termios)
    mov     rax, SYS_IOCTL
    mov     rdi, 0
    mov     rsi, TCSETS
    lea     rdx, [rel new_termios]
    syscall
    ret

; ===========================================================================
; disable_raw_mode: restore original termios
; ===========================================================================
disable_raw_mode:
    mov     rax, SYS_IOCTL
    mov     rdi, 0
    mov     rsi, TCSETS
    lea     rdx, [rel saved_termios]
    syscall
    ret

; ===========================================================================
; cleanup_and_exit: restore terminal and exit cleanly
; ===========================================================================
cleanup_and_exit:
    ; Show cursor again
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel show_cursor]
    mov     rdx, hide_cursor_len    ; same length
    syscall

    ; Final reset + newline
    mov     rax, SYS_WRITE
    mov     rdi, 1
    lea     rsi, [rel ansi_reset_nl]
    mov     rdx, ansi_reset_nl_len
    syscall

    call    disable_raw_mode

    mov     rax, SYS_EXIT
    xor     rdi, rdi
    syscall

; ===========================================================================
; signal handler -- just calls cleanup_and_exit
; ===========================================================================
signal_handler:
    call    cleanup_and_exit        ; no return
    ret

; ===========================================================================
; sigwinch_handler: set the resize_pending flag; main loop will pick it up.
; Signal handlers must be reentrancy-safe; updating a single byte is fine.
; ===========================================================================
sigwinch_handler:
    mov     byte [rel resize_pending], 1
    ret

; ===========================================================================
; update_dimensions: query terminal size via TIOCGWINSZ and set cur_cols,
; cur_rows, cur_px_w, cur_px_h, f_aspect. Falls back to 80x40 on failure.
; ===========================================================================
update_dimensions:
    push    rax
    push    rcx
    push    rdx
    push    rdi
    push    rsi

    ; ioctl(1, TIOCGWINSZ, &winsize) -- query stdout
    mov     rax, SYS_IOCTL
    mov     rdi, 1
    mov     rsi, TIOCGWINSZ
    lea     rdx, [rel winsize]
    syscall
    test    rax, rax
    jns     .got_size

    ; Failed: use fallback defaults
    mov     qword [rel cur_cols], 80
    mov     qword [rel cur_rows], 40
    jmp     .compute

.got_size:
    ; ws_row is at offset 0 (uint16), ws_col at offset 2 (uint16)
    movzx   eax, word [rel winsize]     ; ws_row
    movzx   ecx, word [rel winsize + 2] ; ws_col

    ; Subtract STATUS_ROWS from row count (reserve bottom for info+help)
    sub     eax, STATUS_ROWS
    cmp     eax, 1
    jge     .row_ok
    mov     eax, 1
.row_ok:
    ; Clamp to MAX_ROWS / MAX_COLS
    cmp     eax, MAX_ROWS
    jle     .row_capped
    mov     eax, MAX_ROWS
.row_capped:
    cmp     ecx, 1
    jge     .col_ok
    mov     ecx, 1
.col_ok:
    cmp     ecx, MAX_COLS
    jle     .col_capped
    mov     ecx, MAX_COLS
.col_capped:
    mov     [rel cur_rows], rax
    mov     [rel cur_cols], rcx

.compute:
    ; px_w = cols * 2, px_h = rows * 4
    mov     rax, [rel cur_cols]
    shl     rax, 1
    mov     [rel cur_px_w], rax
    mov     rax, [rel cur_rows]
    shl     rax, 2
    mov     [rel cur_px_h], rax

    ; aspect = px_w / px_h (as double).
    ; Terminal cells are roughly 2:1 tall:wide. Braille is 2x4 subpixels per
    ; cell, so subpixels are ~1:1 (square). Thus px_w/px_h gives the right
    ; aspect for the complex-plane view.
    cvtsi2sd xmm0, [rel cur_px_w]
    cvtsi2sd xmm1, [rel cur_px_h]
    divsd   xmm0, xmm1
    movsd   [rel f_aspect], xmm0

    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rax
    ret

; ===========================================================================
; install_signal_handlers: SIGINT, SIGTERM -> signal_handler
;                          SIGWINCH       -> sigwinch_handler
; ===========================================================================
section .data
    align 8
    sigaction_struct:
        dq  0                       ; sa_handler (filled in)
        dq  0x04000000              ; sa_flags = SA_RESTORER
        dq  sig_restorer            ; sa_restorer
        dq  0                       ; sa_mask
        dq  0
        dq  0
        dq  0

    align 8
    sigwinch_action:
        dq  0                       ; sa_handler (filled in)
        dq  0x04000000              ; sa_flags = SA_RESTORER
        dq  sig_restorer            ; sa_restorer
        dq  0
        dq  0
        dq  0
        dq  0

section .text
sig_restorer:
    mov     rax, 15                 ; SYS_RT_SIGRETURN
    syscall

install_signal_handlers:
    lea     rax, [rel signal_handler]
    mov     [rel sigaction_struct], rax

    ; sigaction(SIGINT, &sigaction_struct, NULL)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGINT
    lea     rsi, [rel sigaction_struct]
    xor     rdx, rdx
    mov     r10, 8                  ; sigsetsize
    syscall

    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGTERM
    lea     rsi, [rel sigaction_struct]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; SIGWINCH -> sigwinch_handler
    lea     rax, [rel sigwinch_handler]
    mov     [rel sigwinch_action], rax
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGWINCH
    lea     rsi, [rel sigwinch_action]
    xor     rdx, rdx
    mov     r10, 8
    syscall
    ret
