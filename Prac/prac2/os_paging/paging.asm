; 
; Practicum Besturingssystemen
;
; dit programma bestaat uit een beperkt aantal sectoren die ingelezen
; worden na het uitvoeren van de BIOS. Dit zijn de eerste sectoren die
; bij het bootstrappen van de floppy of van de harde schijf gelezen 
; worden
;
; de bios begint uit te voeren op adres 000ffff0h (startadres van de 
; processor, en zal na verloop van tijd de eerste sector (512 bytes)
; van het bootstrap device (floppy, harddisk, CD) inlezen.
; 
; deze sector wordt opgeslagen op adres 7c00h.
;

; constantendefinities

Loaded          EQU     7C00h   ; adres waarop sector 0 geladen wordt
SectorSize      EQU     512     ; grootte van 1 sector

VIDEO_MODE      EQU     7       ; monochrome mode
VGA_MEM         EQU     0xB0000 ; plaats van de videoram voor monochrome mode
;VIDEO_MODE      EQU     3       ; kleurmode
;VGA_MEM         EQU     0xB8000 ; plaats van de videoram voor kleurmode

PT_ENTRY_IDX	EQU     0       ; de page table komt als eerste in de page dir table
VGA_PAGE_IDX	EQU     1023
VGA_MEM_MAPPED	EQU     (PT_ENTRY_IDX << 22 | VGA_PAGE_IDX << 12)

Wachtlus        EQU     100000
Displacement    EQU     1024*1024


; de BIOS voert steeds uit in 16 bit mode. Een van de taken van het programma
; in sector 0 is het omschakelen naar 32 bit mode.
; 
; de BITS directieve vraagt aan de assembler om 16-bit code te genereren.
; 
BITS 16     ; 16 bit real mode

; de ORG-directieve vraagt aan de assember ervan uit te gaan dat de volgende 
; instructie uiteindelijk op adres 7C00h in het geheugen terecht zal komen

ORG   7C00h   ; adres waarop deze code geladen wordt

; behalve het codesegment (deze instructies worden immers uitgevoerd), kunnen
; we er niet van uitgaan dat de andere segmentregisters geldige waarden hebben.
; we zorgen ervoor dat ds, es, en ss allemaal naar hetzelfde blok geheugen 
; wijzen.
; Uit experimenten blijkt dat alle segmenten beginnen op adres 0. Let wel: dit 
; zijn segmentregisters uit het IA16 model en hun interpretatie is verschillend van 
; deze in het IA32 model.

  xor ax, ax
  mov ds, ax
  mov es, ax
  mov ss, ax
  mov sp, Loaded    ; sp wijst net voor de eerste instructie, 
                    ; en groeit ervan weg 

; Laad de rest van de sectoren na de eerste sector in het geheugen. 
; Hiervoor wordt de BIOS oproep int 13h gebruikt. Daarvoor moeten wel alle 
; parameters eerst goedgezet worden.
; aangezien niet elke BIOS multitrack reads ondersteunt dienen we de
; sectoren een voor een in te lezen (zou ook per track kunnen)

  mov si, 2     ; SI = huidige logische sector
  mov ax, SecondStage
  shr ax, 4
  mov es, ax
  
load_next:
  ; CL = sector = ((SI -1) % 18) + 1
  ; CH = track = (SI - 1) / 36
  ; DH = head = ((SI - 1) / 18) & 1
  mov ax, si
  dec ax
  xor dx, dx
  mov bx, 18
  div bx
  mov cl, dl
  inc cl
  mov ch, al
  shr ch, 1
  mov dh, al
  and dh, 1
.retry:
  mov ah, 2 ; read sector
  mov al, 1 ; 1 sector
  mov bx, 0 ; buffer es:bx
  mov dl, 0 ; diskette station A:
  int 0x13
  jc .retry
  mov ax, es
  add ax, 0x20  ; 512 bytes / 16
  mov es, ax
  inc si    ; volgende sector
  cmp si, SectorsToLoad + 2
  jnz load_next

; Met de BIOS-interrupt 10h zetten we de videomode goed.
; 25 lijnen van 80 witte tekens met zwarte achtergrond = VGA mode 03h 

  mov ax, VIDEO_MODE 
  int 10h

; Zet motor af
  xor al, al    ; al = 0
  mov dx, 0x3f2 ; FDD Digital Output Register
  out dx, al

; stop interrupts zodat we de onderbrekingsregelaar kunnen programmeren
  cli

; PIC initialization (8259A) 
; PIC1: 0020-003F
; PIC2: 00A0-00BF       
; Maps IRQ 0 - IRQ 0xF to INT 8 - 23
  mov al,11h  ; (init. command word 1) ICW1 to both controllers
  out 20h,al    ; bit 0=1: ICW4 needed
  out 0A0h,al   ; bit 1=0: cascaded mode
                ; bit 2=0: call address interval 8 bytes 
                ; bit 3=0: edge triggered mode
                ; bit 4=1: ICW1 is being issued
                ; bit 5-7: not used
  mov al, IRQBase ; ICW2 PIC1 - offset of vectors
  out 21h,al    ; 20h -> right after the intel exceptions
                ; bit 0-2: 000 on 80x86 systems
                ; bit 3-7: A3-A7 of 80x86 interrupt vector

  mov al, IRQBase+8   ; ICW2 PIC2 - offset of vectors
  out 0A1h,al   ; 28h -> after PIC1 vectors
    
  mov al,4h     ; ICW3 PIC1 (master)
  out 21h,al    ; bit 2=1: irq2 has the slave
    
  mov al,2h     ; ICW3 PIC2 (slave)
  out 0A1h,al   ; bit 1=1: slave id is 2
    
  mov al,1h     ; ICW4 to both controllers
  out 21h,al    ; bit 0=1: 8086 mode
                ; bit 1=0: no auto EOI, so normal EOI
  out 0A1h,al   ; bit 2-3=00: nonbuffered mode
                ; bit 4:0=sequential, bit 5-7: reserved
    
  mov al,0ffh   ; OCW1 interrupt mask to both
  out 21h,al    ; no interrupts enabled
  out 0A1h,al  

; Zet de Global Descriptor Tabel (GDT) goed zodat we cs, ds, es, ss kunnen
; vullen met een segment selector die wijst naar het gehele adresbereik.

  lgdt [GDTInfo] ; laadt GDTR register

; Laat het IDT register wijzen naar de Interrupt Descriptor Tabel (IDT) 
; (die moeten we nog invullen)

  lidt [IDTInfo] ; laadt IDTR register
  
; Het laagste bit in het controleregister cr0 bepaalt of we in 16 bit mode
; of in 32 bit mode werken. 

  mov eax, cr0
  or  eax, 1    ; 1 = protected mode (32 bit)
  mov cr0, eax  

; Spring naar het begin van de 32-bit code Main32. Door gebruik te maken 
; van een intersegmentaire sprong worden zowel cs als eip meteen goed gezet.
; CodeSegmentSelector = selector naar de descriptor van het codesegment
; Main32 = 32-bit entry point

  jmp CodeSegmentSelector:dword main

; de assember zal vanaf hier 32 bit code genereren
BITS 32

; Dit is het einde van de eerste sector. Deze wordt nu opgevuld met nullen
; totdat hij precies 512 bytes groot is. ($-$$)=grootte van de code

; Laat NASM controleren of onze boot sector wel in 512 bytes past.
%if ($-$$) > SectorSize - 2
%error De bootsector is groter dan 512 bytes.
%endif

TIMES SectorSize-2-($-$$) DB 0 ; Zorg dat de boot sector 512 bytes lang is 
DW  0xAA55  ; Verplichte signatuur van de bootsector, hieraan herkent de BIOS een bootsector

;============================ SECOND STAGE SECTION ============================ 
SecondStage: ; de eerste bootsector zal op dit adres de volgende
             ; sectoren inladen met onderstaande code en data
             ; deze sectoren beginnen in principe op Loaded+SectorSize


;-----------------------------------------------------------------------------;
;                          GLOBAL DESCRIPTORS TABLE                           ;
;-----------------------------------------------------------------------------;
; Er worden hier drie segmenten gedefinieerd: codesegment, datasegment, en 
; stapelsegment
; Al deze segmenten wijzen echter naar hetzelfde blok geheugen van 4 GiB 
; (volledige 32-bit adresruimte).

;  db: define byte (8 bit)
;  dw: define word (16 bit)
;  dd: defice double (32 bit)

GDTStart: 
NULLDesc:
  dd 0, 0      ; null descriptor  (wordt niet gebruikt)
CodeDesc:   
  dw 0FFFFh    ; code limit 0 - 15
  dw 0         ; code base 0 - 15
  db 0         ; code base 16 - 23
  db 10011010b ; present=1, dpl=00, 1, code=1, cnf=0, read=1, accessed=0
  db 11001111b ; gran=1, use32=1, 0, 0, limit 16 - 19
  db 0         ; code base 24 - 31
DataDesc: 
  dw 0FFFFh    ; data limit 0 - 15
  dw 0         ; data base 0 - 15
  db 0         ; data base 16 - 23
  db 10010010b ; present=1, dpl=00, 1, code=0, exp.direction=0, write=1, accessed=0
  db 11001111b ; gran=1, use32=1, 0, 0, limit 16 - 19
  db 0         ; data base 24 - 31     
StackDesc: 
  dw 0         ; data limit 0 - 15
  dw 0         ; data base 0 - 15
  db 0         ; data base 16 - 23
  db 10010110b ; present=1, dpl=00, 1, code=0, exp.direction=1, write=1, accessed=0
  db 11000000b ; gran=1, use32=1, 0, 0, limit 16 - 19
  db 0         ; data base 24 - 31     
GDTEnd: 

GDTInfo:                        ; inhoud van GDTR
GDTLimit  dw  GDTEnd-GDTStart-1 ; GDT limit = offset hoogste byte  
GDTBase   dd  GDTStart          ; GDT base 

; constantendefinities om gemakkelijk naar de verschillende segmenten
; te kunnen refereren.

CodeSegmentSelector   EQU CodeDesc - GDTStart
DataSegmentSelector   EQU DataDesc - GDTStart
StackSegmentSelector  EQU StackDesc - GDTStart

;-----------------------------------------------------------------------------;
;                          INTERRUPT DESCRIPTORS TABLE                        ;
;-----------------------------------------------------------------------------;
; De eerste 32 onderbrekingen worden door Intel gedefinieerd. De onderbrekingen
; afkomstig van de onderbrekingsregelaar starten bij onderbreking 32

IDTStart:
  dd  0, 0  ; INT 0 : Divide error
  dd  0, 0  ; INT 1 : Single Step
  dd  0, 0  ; INT 2 : Nonmaskable interrupt
  dd  0, 0  ; INT 3 : Breakpoint
  dd  0, 0  ; INT 4 : Overflow
  dd  0, 0  ; INT 5 : BOUND range exceeded
  dd  0, 0  ; INT 6 : invalid opcode
  dd  0, 0  ; INT 7 : device not available (no math co-cpu)
  dd  0, 0  ; INT 8 : double fault  
  dd  0, 0  ; INT 9 : co-cpu segment overrun
  dd  0, 0  ; INT 10 : invalid TSS
  dd  0, 0  ; INT 11 : segment not present
  dd  0, 0  ; INT 12 : stack-segment fault
  dd  0, 0  ; INT 13 : general protection
  dd  0, 0  ; INT 14 : page fault
  dd  0, 0  ; INT 15 : reserved 
  dd  0, 0  ; INT 16 : x87 FPU error 
  dd  0, 0  ; INT 17 : alignment check 
  dd  0, 0  ; INT 18 : machine check 
  dd  0, 0  ; INT 19 : SIMD floating-point exception 
  dd  0, 0  ; INT 20 : reserved
  dd  0, 0  ; INT 21 : reserved
  dd  0, 0  ; INT 22 : reserved
  dd  0, 0  ; INT 23 : reserved
  dd  0, 0  ; INT 24 : reserved
  dd  0, 0  ; INT 25 : reserved
  dd  0, 0  ; INT 26 : reserved
  dd  0, 0  ; INT 27 : reserved
  dd  0, 0  ; INT 28 : reserved
  dd  0, 0  ; INT 29 : reserved
  dd  0, 0  ; INT 30 : reserved
  dd  0, 0  ; INT 31 : reserved
  dd  0, 0  ; INT 32 : IRQ0 timer
  dd  0, 0  ; INT 33 : IRQ1 keyboard, mouse, rtc
  dd  0, 0  ; INT 34 : IRQ2 2de PIC
  dd  0, 0  ; INT 35 : IRQ3 com1
  dd  0, 0  ; INT 36 : IRQ4 serial port 2 (=com2)
  dd  0, 0  ; INT 37 : IRQ5 hard disk
  dd  0, 0  ; INT 38 : IRQ6 diskette controller
  dd  0, 0  ; INT 39 : IRQ7 parallel printer
  dd  0, 0  ; INT 40 : IRQ8 real-time clock
  dd  0, 0  ; INT 41 : IRQ9 redirect cascade
  dd  0, 0  ; INT 42 : IRQ10 reserved
  dd  0, 0  ; INT 43 : IRQ11 reserved
  dd  0, 0  ; INT 44 : IRQ12 mouse
  dd  0, 0  ; INT 45 : IRQ13 coprocessor exeception interrupt
  dd  0, 0  ; INT 46 : IRQ14 fixed disk
  dd  0, 0  ; INT 47 : IRQ15 reserved
IDTEnd:

IRQBase   EQU 32

IDTInfo:                        ; Inhoud van IDTR
IDTLimit  dw  IDTEnd-IDTStart-1 ; limit = offset hoogste byte 
IDTBase   dd  IDTStart

;------------------------------------------------------------------------------
;                      PAGE DIRECTORY TABLES & PAGE TABLES
;------------------------------------------------------------------------------
; Laat NASM de grootte van voorgaande sectie controleren
%if ($-SecondStage) > SectorSize
%error Voorgaande sectie is groter dan 512 bytes.
%endif

TIMES (SectorSize - ($-SecondStage)) DB 0	

; een page (directory) table dient mooi op een page
; boundary (=0x1000, 0x2000, 0x3000, ...) te beginnen.
; SecondStage heeft adres 0x7E00, dus: 0x7E00 + 512 = 0x8000
; Noot: We kunnen 'ALIGN 4096' helaas niet gebruiken.
PageTable:
  ; initialiseer de afbeelding voor de eerste 48 virtueel -> fysisch geheugen
  ; (dit is zeker genoeg voor onze code, stack en data). Denk eraan dat onze
  ; .bin bestand op adres 0x7c00 geladen wordt en alle code/data daarboven zit.
  ; De stapel, interrupt vector tabel en bios data zitten er onder.
  DD Displacement|3
  DD 01000h+Displacement|3
  DD 02000h+Displacement|3
  DD 03000h+Displacement|3
  DD 04000h+Displacement|3
  DD 05000h+Displacement|3
  DD 06000h+Displacement|3
  DD 07000h+Displacement|3
  DD 08000h+Displacement|3
  DD 09000h+Displacement|3
  DD 0A000h+Displacement|3
  DD 0B000h+Displacement|3
  DD 3
  DD 01000h|3
  DD 02000h|3
  DD 03000h|3
  DD 04000h|3
  DD 05000h|3
  DD 06000h|3
  DD 07000h|3
  DD 08000h|3
  DD 09000h|3
  DD 0A000h|3
  DD 0B000h|3
  TIMES 0x3E7 DD 0
  DD VGA_MEM|3

    

  


%if ($ - PageTable) != 4096
%error De grootte van de paginatabel is verschillend van 4096 bytes
%endif 

PageDirTable:
TIMES 1024	DD 0

;================================= MAIN ==============================

main: 

; door de oproep met expliciet codesegment staat het codesegment-register 
; hier meteen goed. De andere segmentregisters krijgen hier een waarde.
; alle segmentregisters (ook fs en gs) dienen met een geldige waarde te worden
; gevuld.

  mov ax, DataSegmentSelector
  mov ds, ax    
  mov es, ax    
  mov fs, ax  
  mov gs, ax  

  mov ax, StackSegmentSelector
  mov ss, ax
  mov esp, Loaded     ; stapel wijst nog steeds naar dezelfde locatie

  sti                 ; zet de onderbrekingen terug aan

  mov esi, Loaded
  mov edi, Loaded
  add edi, Displacement
  mov ecx, 12288
  rep movsd



  ; initialiseer de page directory table en page table
  ; laat de page directory table naar onze page table verwijzen
  mov eax, PageTable + Displacement
  or eax, 1|2 	; flags: 1=present; 2=read/write 
  mov dword [PageDirTable + PT_ENTRY_IDX * 4 + Displacement], eax

  ; de page directory table en page table zijn nu reeds correct
  ; ingevuld om paging in de CPU te kunnen activeren.



  ; laad het page directory table register
  mov eax, PageDirTable + Displacement
  mov cr3, eax

  ; activeer paging
  mov eax, cr0
  or eax, 1 << 31
  mov cr0, eax
  jmp near .near	; Intel raadt hier een near jump aan
  
.near:
  mov eax, 0xCCCCCCCC
  mov edi, 0xb800
  mov ecx, 12288
  rep stosd
; teken een spiraal
  mov eax,0 
  mov ebx,79
  mov ecx,0
  mov edx,20
  jmp spiraal

;================================= HULPFUNCTIES ==============================
printchar:
  push eax
  push ebx
  push ecx
  push edx
  xor eax,eax
  xor ebx,ebx
  xor ecx,ecx
  mov ax,[esp+24]  ; rij
  mov bx,[esp+22]  ; kol
  mov cx,[esp+20]  ; char
  mov ch,020h
  mov dx,ax
  shl ax,2
  add ax,dx
  shl ax,5
  shl bx,1
  add bx,ax
  mov [VGA_MEM_MAPPED+ebx],cx
  pop edx
  pop ecx
  pop ebx
  pop eax
  ret 6

;
; print een volledige string op het scherm totdat 0 bereikt wordt.
; op de stapel staan, in deze volgorde
;   rij op het scherm (0..24)
;   kolom op het scherm (0..79)
;   het adres van de nulgetermineerde string
;
printstring:
  mov eax,[esp+12]  ; rij
  mov ebx,[esp+8]   ; kol
  mov ecx,[esp+4]   ; pointer naar string
printloop:
  mov dl,[ecx]
  cmp dl,0
  je  stop
  push ax
  push bx
  push dx
  call printchar
  inc ecx
  inc ebx
  jmp printloop
stop:
  ret 12

;
; printint print een natuurlijk getal op het scherm
; op de stapel staan, in deze volgorde
;   rij op het scherm (0..24)
;   kolom op het scherm (0..79)
;   getal zelf 
; het getal wordt omgezet in een stringvoorstelling die 
; gevisualiseerd wordt zonder leidende nullen.
;

printint:
  push ebp
  mov ebp,esp
  sub esp,28
  mov ecx,8
  mov byte [ebp-19],0
  mov eax, [ebp+8]    ; integer argument
  mov ebx,10
bindec: 
  xor edx,edx
  idiv ebx
  add dl,'0'
  mov [ebp-28+ecx],dl
  dec ecx
  cmp eax,0
  jnz bindec
  lea ecx,[ebp-27+ecx]
  push dword [ebp+16]  ; rij
  push dword [ebp+12]  ; kolom
  push ecx
  call printstring
  add esp,28
  pop ebp
  ret 12

;
; printhex print een 32 bit bitpatroon op het scherm in hex notatie
; op de stapel staan, in deze volgorde
;   rij op het scherm (0..24)
;   kolom op het scherm (0..79)
;   32-bit bitpatroon zelf 
; het getal wordt omgezet in hexadecimale voorstelling (8 tekens) die 
; gevisualiseerd wordt 
;

printhex:
  push ebp
  mov ebp,esp
  sub esp,12
  mov ecx,7
  mov eax, [ebp+8]    ; argument
  mov ebx,16
  mov byte [ebp-4],0
binhex: 
  xor edx,edx
  idiv ebx
  cmp dl, 9
  jg alfa
  add dl,'0'
  jmp hex
alfa: 
  add dl,'A'-10
hex:  
  mov [ebp-12+ecx],dl
  dec ecx
  cmp ecx,0
  jge binhex
  push dword [ebp+16]  ; rij
  push dword [ebp+12]  ; kolom
  push ebp
  sub dword [esp],12
  call printstring
  add esp,12
  pop ebp
  ret 12

;
; de routine printad print de inhoud van de voornaamste registers uit op
; lijnen 22, 23, en 24.
; op de stapel staan, in deze volgorde (allemaal 32 bit)
; gs
; fs
; ss
; es
; ds
; cs
; eflags
; eip 
; esp
; dword [ebp]
; edi
; esi
; edx
; ecx
; ebx
; eax
; 


;
; deze functie produceert de hoofdletters van het alfabet
; in het laagste byte van register esi.Per oproep wordt er 1 letter
; opgeschoven. Na Z komt terug A. Indien de oorspronkelijke waarde ' ' was,
; dan blijft deze behouden.
;

nextchar:
  cmp si,' '
  je einde
  cmp si,'Z'
  je herbegin
  inc si
  jmp einde
herbegin:
  mov si,'A'
einde:
  ret

; 
; kleine vertraging om het hoofdprogramma volgbaar te houden.
; De vertraging kan ingesteld worden via de constante 'Wachtlus'
;

ShortDelay:
  push ecx
  mov ecx, Wachtlus
.loop:
  loop .loop 
  pop ecx
  ret


; deze routine tekent een spiraal op het scherm in een gegeven rechthoek
; input
;   ax = meest linkse kolom
;   bx = meest rechtse kolom
;   cx = bovenste rij
;   dx = onderste rij
;
; deze routine termineert nooit (blijft steeds maar spiralen tekenen).

spiraal:
  shl eax,16
  shl ebx,16
  shl ecx,16
  shl edx,16
  mov si,' '
herstart:
  cmp si,' '
  je  letters
  mov si,' '
  jmp eindelus
letters:
  mov si,'A'
eindelus: 
  mov edi,eax
  shr edi,16
  mov ax,di
  mov edi,ebx
  shr edi,16
  mov bx,di
  mov edi,ecx
  shr edi,16
  mov cx,di
  mov edi,edx
  shr edi,16
  mov dx,di
lus1: 
  mov di,ax
  cmp di,bx
  jg  herstart
lus2: 
  push cx
  push di
  push si
  call printchar
  call nextchar
  call ShortDelay
  inc di
  cmp di,bx
  jle lus2
  inc cx
  mov di,cx
  cmp di,dx
  jg herstart
lus3: 
  push di
  push bx
  push si
  call printchar
  call nextchar
  call ShortDelay
  inc di
  cmp di,dx
  jle lus3
  dec bx
  mov di,bx
  cmp di,ax
  jl herstart
lus4: 
  push dx
  push di
  push si
  call printchar
  call nextchar
  call ShortDelay
  dec di
  cmp di,ax
  jge lus4
  dec dx
  mov di,dx
  cmp di,cx
  jl herstart
lus5: 
  push di
  push ax
  push si
  call printchar
  call nextchar
  call ShortDelay
  dec di
  cmp di,cx
  jge lus5
  inc ax
  jmp lus1    

TotalSize       EQU $-$$
TotalSectors    EQU (TotalSize + SectorSize) / SectorSize
SectorsToLoad   EQU TotalSectors - 1 ; TotalSectors - 1 want BIOS heeft de eerste voor ons reeds geladen

TIMES TotalSectors*SectorSize-($-$$) DB 0 ; Zorg dat de laatste sector 512 bytes lang is
