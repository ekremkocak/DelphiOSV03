[BITS 16]
[ORG 0x7E00]            ; Stage 1 bu kodu buraya yükledi

jmp stage2_start

; ============================================================================
; --- Configuration Constants ---
; ============================================================================
KERNEL_SEG          equ 0x4000      ; Segment where kernel will be loaded
KERNEL_OFF          equ 0x0000      ; Offset where kernel will be loaded
FAT_BUFFER_SEG      equ 0x3000      ; Temporary segment to load FAT sectors
DIR_BUFFER_SEG      equ 0x4000      ; Temporary segment to load Directory sectors

; --- BPB'den dinamik doldurulacak deðiþkenler ---
BytesPerSector      dw 0
SectorsPerCluster   db 0
ReservedSectors     dw 0
NumberOfFATs        db 0
SectorsPerFat32     dd 0
RootCluster         dd 0
DriveNumber         db 0

; --- Internal Math Variables ---
FatStartSector      dd 0
DataStartSector     dd 0
KernelCluster       dd 0

; --- Target Kernel Filename (8.3 format, 11 bytes, padded with spaces) ---
;KernelName          db "KERNEL  BIN"
KernelName db "KERNEL  EXE"
E820_BUFFER equ 0x0005000   ; 512 KB üstü
E820_COUNT  equ 0x0005500

KERNEL_STACKSIZE  equ 0x4000

; ============================================================================
; --- Stage 2 Entry Point ---
; ============================================================================
stage2_start:
    ; 1. Normalize Segments
    xor ax, ax
    mov ds, ax
    mov es, ax

    ; 2. Initialize Stack Safely below Stage 1 (0x7C00)
    mov ss, ax
    mov sp, 0x7C00

    ; ------------------------------------------------------------------
    ; 2.5. BPB BÝLGÝLERÝNÝ 0x7C00 ADRESÝNDEKÝ STAGE 1 TABLOSUNDAN OKU
    ; ------------------------------------------------------------------
    mov ax, [0x7C00 + 11]           ; BytesPerSector
    mov [BytesPerSector], ax

    mov al, [0x7C00 + 13]           ; SectorsPerCluster
    mov [SectorsPerCluster], al

    mov ax, [0x7C00 + 14]           ; ReservedSectors
    mov [ReservedSectors], ax

    mov al, [0x7C00 + 16]           ; NumberOfFATs
    mov [NumberOfFATs], al

    mov eax, [0x7C00 + 36]          ; SectorsPerFat32
    mov [SectorsPerFat32], eax

    mov eax, [0x7C00 + 44]          ; RootCluster
    mov [RootCluster], eax

    mov al, [0x7C00 + 64]           ; DriveNumber (Extended BPB)
    mov [DriveNumber], al
    ; ------------------------------------------------------------------

    mov si, msg_stage2
    call print_string

    ; 3. FAT32 Dosya Sistemi Düzenini Hesapla
    mov ax, [ReservedSectors]
    movzx eax, ax
    mov [FatStartSector], eax

    movzx eax, byte [NumberOfFATs]
    mul dword [SectorsPerFat32]     ; eax = NumberOfFATs * SectorsPerFat32
    add eax, [FatStartSector]
    mov [DataStartSector], eax

    ; 4. Root Directory'yi Yükle ve KERNEL.BIN'i Ara
    mov eax, [RootCluster]
    call cluster_to_lba

.read_root_sector:
    mov bx, DIR_BUFFER_SEG
    mov es, bx
    xor bx, bx

    movzx cx, byte [SectorsPerCluster]
    call read_sectors_lba

    xor di, di
.search_loop:
    cmp byte [es:di], 0x00
    je near .kernel_not_found

    push si
    push di
    mov si, KernelName
    mov cx, 11
    repe cmpsb
    pop di
    pop si
    je .kernel_found

    add di, 32
    cmp di, 0x2000                  ; 1 cluster'lýk DIR_BUFFER (8KB) sýnýrý
    jl .search_loop

    jmp near .kernel_not_found

; ============================================================================
; --- KERNEL.BIN Bulundu: Cluster Numarasýný Oku ---
; ============================================================================
.kernel_found:
    ; Directory entry'de cluster numarasý:
    ;   offset 0x14-0x15 = high word (FAT32)
    ;   offset 0x1A-0x1B = low word
    xor eax, eax
    mov ax, [es:di + 0x14]          ; high word -> eax alt 16 bite
    shl eax, 16                      ; high word -> eax üst 16 bite kaydýr
    mov dx, [es:di + 0x1A]          ; low word -> dx
    movzx edx, dx
    or  eax, edx                     ; eax = (high << 16) | low
    mov [KernelCluster], eax

    mov si, msg_loading
    call print_string

    ; 5. Kernel Cluster Zincirini Hedef Belleðe Yükle
    mov bx, KERNEL_SEG
    mov es, bx
    xor bx, bx

.load_kernel_loop:
    mov eax, [KernelCluster]
    call cluster_to_lba

    movzx cx, byte [SectorsPerCluster]
    call read_sectors_lba

    ; --------------------------------------------------------------
    ; Hedef ES segmentini bir sonraki cluster için ilerlet.
    ; (SectorsPerCluster * BytesPerSector) byte = paragraf cinsinden / 16
    ; Taþmayý önlemek için 32-bit aritmetik kullanýlýyor.
    ; --------------------------------------------------------------
    movzx eax, byte [SectorsPerCluster]
    movzx ecx, word [BytesPerSector]
    mul ecx                          ; edx:eax = SectorsPerCluster * BytesPerSector (32-bit yeterli)
    shr eax, 4                       ; byte -> paragraf (16 byte = 1 paragraf)

    mov cx, es
    movzx ecx, cx
    add eax, ecx
    mov es, ax

    ; --------------------------------------------------------------
    ; FAT'tan bir sonraki cluster numarasýný oku
    ; FAT32 entry adresi = FatStartSector*BytesPerSector + KernelCluster*4
    ; --------------------------------------------------------------
    mov eax, [KernelCluster]
    shl eax, 2                       ; eax = cluster_number * 4 (byte ofset)

    xor edx, edx
    movzx ecx, word [BytesPerSector]
    div ecx                          ; eax = FAT sektör ofseti, edx = sektör içi byte ofseti
    push edx                         ; byte ofsetini sakla

    add eax, [FatStartSector]        ; eax = okunacak FAT sektörünün LBA'sý

    push es
    mov cx, FAT_BUFFER_SEG
    mov es, cx
    xor bx, bx
    mov cx, 1
    call read_sectors_lba
    pop es

    pop edx                          ; edx = sektör içi byte ofseti
    mov di, dx                       ; di = ofset (sektör boyutu <= 65535, güvenli)

    push ds
    mov cx, FAT_BUFFER_SEG
    mov ds, cx
    mov eax, [di]                    ; DS:DI -> FAT entry oku (4 byte)
    pop ds

    and eax, 0x0FFFFFFF               ; üst 4 bit rezerve, maskele
    mov [KernelCluster], eax

    cmp eax, 0x0FFFFFF8
    jae .kernel_load_finished
    jmp .load_kernel_loop

.kernel_load_finished:
    mov si, msg_jump
    call print_string
    call enable_a20
    ; 6. 32-bit Korumalý Moda Geçiþ
    cli
    lgdt [gdt_descriptor]
    call read_e820
    mov eax, cr0
    or eax, 1                        ; PE bitini aç
    mov cr0, eax

    ; Pipeline'ý temizle ve CS'i 32-bit kod seçicisine (0x08) ayarla
    jmp dword 0x08:protected_mode_entry

; ============================================================================
.kernel_not_found:
    mov si, msg_error
    call print_string
    cli
    hlt
    jmp $

; ============================================================================
; --- Helper Functions (16-bit) ---
; ============================================================================
print_string:
    pusha
    mov ah, 0x0E
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    popa
    ret

; eax = cluster numarasý girdi olarak gelir, eax = LBA olarak döner
cluster_to_lba:
    sub eax, 2
    movzx ecx, byte [SectorsPerCluster]
    mul ecx                          ; eax = (cluster-2) * SectorsPerCluster
    add eax, [DataStartSector]
    ret

; eax = LBA, cx = sektör sayýsý, es:bx = hedef buffer
read_sectors_lba:
    pusha
    mov [dap_lba], eax
    mov [dap_count], cx
    mov [dap_offset], bx
    mov [dap_segment], es

    mov ah, 0x42
    mov dl, [DriveNumber]
    mov si, disk_address_packet
    int 0x13
    jc .read_failed
    popa
    ret
.read_failed:
    mov si, msg_disk_err
    call print_string
    cli
    hlt

align 4
disk_address_packet:
    dap_size     db 0x10
    dap_reserved db 0x00
    dap_count    dw 0
    dap_offset   dw 0
    dap_segment  dw 0
    dap_lba      dq 0

; ============================================================================
; --- Global Descriptor Table (GDT) ---
; ============================================================================
align 4
gdt_start:
    dq 0                              ; Null descriptor

gdt_code:                             ; 0x08 - 32-bit Kod Segmenti
    dw 0xFFFF                         ; Limit (0-15)
    dw 0x0000                         ; Base  (0-15)
    db 0x00                           ; Base  (16-23)
    db 10011010b                      ; Access: present, ring0, code, exec/read
    db 11001111b                      ; Flags(4-bit) + Limit(16-19): 4K gran, 32-bit
    db 0x00                           ; Base  (24-31)

gdt_data:                             ; 0x10 - 32-bit Veri Segmenti
    dw 0xFFFF                         ; Limit (0-15)
    dw 0x0000                         ; Base  (0-15)
    db 0x00                           ; Base  (16-23)
    db 10010010b                      ; Access: present, ring0, data, read/write
    db 11001111b                      ; Flags(4-bit) + Limit(16-19): 4K gran, 32-bit
    db 0x00                           ; Base  (24-31)

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start
    
    
; ============================================================================
; --- A20 Line Etkinleþtirme Fonksiyonu ---
; ============================================================================
enable_a20:
    pusha

    ; 1. Yöntem: BIOS ile A20 Açmayý Dene (Ýnt 15h, AX=2401h)
    mov ax, 0x2401
    int 0x15
    jnc .a20_done           ; Çýkýþ bayraðý (Carry Flag) temizse iþlem baþarýlýdýr

    ; 2. Yöntem: Baþarýsýz olursa Fast A20 Portu (Port 92h) üzerinden dene
    in al, 0x92
    test al, 2              ; A20 zaten açýk mý?
    jnz .a20_done
    or al, 2                ; Bit 1'i set et (A20 Gönderimi aktifleþsin)
    and al, 0xFE            ; Bit 0'ý temizle (Sistem resetlenmesin diye)
    out 0x92, al

.a20_done:
    popa
    ret
    
read_e820:
    push ebp
    push esi
    push edi
    push ebx
    push ds
    pop es

    mov di, E820_BUFFER
    xor ebx, ebx
    mov edx, 0x534D4150
    xor bp, bp

.next_entry:
    mov eax, 0xE820
    mov ecx, 24          ; ‹ 20 yerine 24!
    int 0x15
    jc .done
    cmp eax, 0x534D4150
    jne .done
    test ecx, ecx
    jz .skip_entry
    inc bp

.skip_entry:
    test ebx, ebx
    jz .done
    add di, 24           ; ‹ 20 yerine 24!
    jmp .next_entry

.done:
    mov [E820_COUNT], bp
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret
    
; ============================================================================
; --- 32-bit Korumalý Mod Ortamý ---
; ============================================================================
[BITS 32]
  %define TEXT_BUFFER 0x000B8000 ; Text buffer address
  %include "peldr32.asm"

protected_mode_entry:
    ; Korumalý Mod veri segmentlerini GDT Veri Seçicisi (0x10) ile güncelle
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    mov al, 0x0FF
    out 0x0A1, al
    out 0x021, al ; Mask 8259A
    mov esi, 0x40000 ; Address of kernel in memory
    jmp pe_load ; Load kernel PE binary
    
    
print32:
	pushad
	xor edx, edx
	add edi, TEXT_BUFFER ; Add text buffer address to offset
.load_char:
	lodsb
	cmp al, 0x0A ; Check for newline
	je .newline
	test al, al ; If zero, stop printing
	jz .end

	mov word [edi], ax ; Write character
	add edi, 2 ; Next character
	add edx, 2 ; Save the offset for newline
	jmp .load_char
.newline:
	mov ecx, 160 ; 80 (Buffer width) * 2
	sub ecx, edx
	add edi, ecx ; Check how many spaces to add for a newline
	xor edx, edx
	jmp .load_char
.end:
	popad
	ret



hex_buffer: db "00000000", 0


; ============================================================================
; --- Data Structures & Strings ---
; ============================================================================
msg_stage2   db "Stage 2 Loaded Successfully (Dinamik BPB)...", 0x0D, 0x0A, 0
msg_loading  db "Loading Kernel...", 0x0D, 0x0A, 0
msg_jump     db "Jumping to Protected Mode...", 0x0D, 0x0A, 0
msg_error    db "Critical Error: KERNEL.EXE missing!", 0x0D, 0x0A, 0
msg_disk_err db "Disk Read Failure!", 0x0D, 0x0A, 0

; Stage 2'nin sektör hizalamasý için padding (gerekirse)
;times 10096-($-$$) db 0

section .bss

align 32
KERNEL_STACK:
        resb KERNEL_STACKSIZE
