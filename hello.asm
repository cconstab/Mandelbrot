; hello.asm - "Hello, World!" in x86-64 Linux assembly
; Uses raw syscalls; no libc, no dependencies.
;
; Assemble: nasm -f elf64 hello.asm -o hello.o
; Link:     ld hello.o -o hello
; Run:      ./hello

section .data
    msg     db  "Hello, World!", 10    ; 10 = newline
    msglen  equ $ - msg                 ; length of msg

section .text
    global _start

_start:
    ; write(1, msg, msglen)
    mov     rax, 1          ; syscall number for sys_write
    mov     rdi, 1          ; file descriptor 1 = stdout
    mov     rsi, msg        ; pointer to message
    mov     rdx, msglen     ; message length
    syscall

    ; exit(0)
    mov     rax, 60         ; syscall number for sys_exit
    mov     rdi, 0          ; exit status 0
    syscall
