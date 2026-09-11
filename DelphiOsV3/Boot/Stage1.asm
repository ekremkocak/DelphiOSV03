[BITS 16]
[ORG 0x7C00]

jmp short start
nop

; --- FAT32 Extended BIOS Parameter Block (BPB) ---
oem_name            db "MSWIN4.1"
bytes_per_sector    dw 512
sectors_per_cluster db 8
reserved_sectors    dw 32
num_fats            db 2
root_entries        dw 0
total_sectors_16    dw 0
media_type          db 0xF8
sectors_per_fat_16  dw 0
sectors_per_track   dw 32
num_heads           dw 64
hidden_sectors      dd 0
total_sectors_32    dd 0x200000      ; Örnek: 1GB Disk

; FAT32 Geniþletilmiþ Alaný
sectors_per_fat_32  dd 1024
ext_flags           dw 0
fs_version          dw 0
root_cluster        dd 2
fs_info             dw 1
bk_boot_sector      dw 6
reserved            times 12 db 0
drive_number        db 0x80
reserved1           db 0
boot_signature      db 0x29
volume_id           dd 0x12345678
volume_label        db "MYOS       "
file_system_type    db "FAT32   "

start:
    ; Segmentleri sýfýrla
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; Sürücü numarasýný kaydet
    mov [drive_number], dl

    ; Dosya sistemi konumlarýný hesapla
    ; DataStart = ReservedSectors + (NumFATs * SectorsPerFat32)
    movzx eax, byte [num_fats]
    mul dword [sectors_per_fat_32]
    add ax, [reserved_sectors]
    mov [data_start], eax

    ; Kök dizin LBA'sýný hesapla (Cluster 2)
    mov eax, [root_cluster]
    call cluster_to_lba

    ; Kök dizini geçici olarak Stage 2'nin yükleneceði yere oku (0x7E00)
    mov bx, 0x7E00
    mov cx, 1
    call read_sectors

    ; STAGE2.BIN dosyasýný ara
    mov di, 0x7E00
.search_loop:
    cmp byte [di], 0
    je .not_found
    
    mov si, stage2_name
    mov cx, 11
    push di
    repe cmpsb
    pop di
    je .found
    
    add di, 32
    jmp .search_loop

.found:
    ; Dosyanýn ilk kümesini (cluster) al
    mov ax, [di + 0x14] ; Yüksek 16-bit
    shl eax, 16
    mov ax, [di + 0x1A] ; Düþük 16-bit
    
    ; Stage 2'yi 0x7E00 adresine yükle
    mov bx, 0x7E00
    call cluster_to_lba
    movzx cx, byte [sectors_per_cluster]
    call read_sectors

    ; Stage 2'ye zýpla!
    mov dl, [drive_number]
    jmp 0x0000:0x7E00

.not_found:
    mov si, err_msg
.print:
    lodsb
    test al, al
    jz .halt
    mov ah, 0x0E
    int 0x10
    jmp .print
.halt:
    hlt
    jmp $

; --- Yardýmcý Fonksiyonlar ---
cluster_to_lba:
    sub eax, 2
    movzx ecx, byte [sectors_per_cluster]
    mul ecx
    add eax, [data_start]
    ret

read_sectors:
    pusha
    mov [dap_lba], eax
    mov [dap_count], cx
    mov [dap_offset], bx
    mov [dap_segment], es
    mov ah, 0x42
    mov dl, [drive_number]
    mov si, disk_address_packet
    int 0x13
    popa
    ret

; --- Veriler ---
stage2_name db "STAGE2  BIN"
err_msg     db "Stage 2 bulunamadi!", 0
data_start  dd 0

align 4
disk_address_packet:
    db 0x10, 0x00
dap_count:   dw 0
dap_offset:  dw 0
dap_segment: dw 0
dap_lba:     dq 0

times 510-($-$$) db 0
dw 0xAA55

