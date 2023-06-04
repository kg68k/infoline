.title infoline - INFORMATION LINE

# This file is part of infoline
# Copyright (C) 2023 TcbnErik
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

program:  .reg 'infoline'
version:  .reg '2.0.0'
ver_id:   .equ $02_00_00_00
date:     .reg '2023-06-04'
author:   .reg 'TcbnErik'


.include iomap.mac
.include macro.mac
.include vector.mac
.include console.mac
.include doscall.mac
.include iocscall.mac
.include iocswork.mac
.include twoncall.mac


;定数
;__ $0000 mpu:68000(00MHz) cache:___ int:________ twon:_________ pcm8:___ 0000-00-00(__) 00:00:00
;             68000@xxxMHz
WIDTH: .equ 96
X0:    .equ 2  ;左端二桁は console driver で使う

JMP_ABSL_CODE: .equ $4ef9
BCC_CODE:      .equ $6400

CACHE_V: .equ 7
CACHE_D: .equ 1
CACHE_I: .equ 0

.ifndef DEFAULT_COLOR
  DEFAULT_COLOR: .equ 2
.endif
COLOR_MAX: .equ 15

DATE_SEP: .equ '-'


;I/O アドレス
XT30_IO3: .equ $ecc000

VX_CTRL: .equ $ecf000
VX_ID1:  .equ $ecf004
VX_ID2:  .equ $ecf008
VX_REV:  .equ $ecf00c


;Human68k バージョン依存アドレス
ExitCode: .equ $1cae

HUMAN302_FNCCLR:  .equ $fd26+$a
HUMAN302_FNCRET:  .equ $fe00
HUMAN302_FNCPAT1: .equ $fe20+$6
HUMAN302_FNCPAT2: .equ $fe20+$c
HUMAN302_FNCDISP: .equ $fe20+$e
HUMAN302_HENDSP0: .equ $ff22+$0
HUMAN302_HENDSP3: .equ $ff22+$c


;IOCSコール 直接呼び出しマクロ
_IOCS: .macro areg,callno
  suba.l a5,a5
  movea.l (callno*4+IOCS_VECTBL),areg
  jsr (areg)
.endm


.cpu 68000

.text
.even


;常駐部
keep_start:
start:
  bra.s start2
  .dc.b '#HUPAIR',0
start2:
  bra.w   start3

old_tma_vec: .equ $-8  ;.dc.l 0
old_rtc_vec: .equ $-4  ;.dc.l 0

keep_id: .dc.l 'Info','Line',ver_id


;RTC 16Hz 割り込み処理
;注意 1. keep_id から rtc_int_job の間には何も置かないこと
;     2. 割り込み処理内での IOCS コールは _IOCS マクロを使うこと

rtc_int_job:
tma_int_job:
  PUSH d0-d7/a0-a6
  cmpi.b  #2,(T_USEMD)
  bne @f
    btst #3,(CRTC_ACTL)
    bne  rtc_int_job_end  ;SCD 起動中
  @@:
  lea (injob_flag,pc),a6

  tas (a6)+
  bmi rtc_int_job_end  ;多重割り込みは無視

    moveq #SR_I_MASK>>8,d0
    and.b (4*(8+7),sp),d0  ;0～7
    add d0,d0                    ;割り込みプライオリティマスクを
    move (sr_table,pc,d0.w),sr   ;割り込み発生前の値に戻す

    bsr update_line

    move.b #%1000,(RTC_RESET)  ;RTC 16Hz 割り込みを再設定する
    clr.b -(a6)  ;injob_flag をクリア

  rtc_int_job_end:
  POP d0-d7/a0-a6
  rte

sr_table:
  .dc $2000,$2100,$2200,$2300
  .dc $2400,$2500,$2600,$2700


;終了コードの表示
UPDATE_ECODE: .macro
  move (ExitCode+2),d0
  cmp (old_ecode,pc),d0
  beq update_ecode_end

  lea (ecode,pc),a1
  lea (a1),a2
  move d0,(old_ecode-ecode,a1)
  cmpi #$000f,d0
  bhi @f
    move.b (hex_table,pc,d0.w),(a2)+
    bra update_ecode_pad
  @@:
  moveq #4-1,d2
  update_ecode_loop:
    rol #4,d0  ;$0010 以上は四桁 0 詰めで表示
    moveq #$f,d1
    and d0,d1
    move.b (hex_table,pc,d1.w),(a2)+
  dbra d2,update_ecode_loop
update_ecode_pad:
  moveq #' ',d0
  cmp.b (a2),d0
  beq @f
  update_ecode_loop2:
    move.b  d0,(a2)+  ;残っている数字を消す
    cmp.b (a2),d0
    bne update_ecode_loop2
  @@:
  tst.b (a6)
  bpl update_ecode_end      ;後でまとめて表示する

  moveq #X0+(ecode-buf),d2  ;今すぐ表示する
  move.l a2,d4
  sub.l a1,d4
  subq #1,d4
  PUTMES
update_ecode_end:
.endm


;キャッシュ状態の表示
UPDATE_CACHE: .macro
  move.b (cache_type,pc),d0
  beq update_cache_end  ;キャッシュなし

  ;キャッシュ状態を収得する
  moveq #0,d2
  tst.b d0
  bpl update_cache_no_vx  ;VENUS-X なし
    moveq #1<<CACHE_V,d2
    and.l (VX_CTRL),d2
    cmpi.b #2,(MPUTYPE)
    bcs @f  ;なんとなく
  update_cache_no_vx:

  moveq #1,d1  ;キャッシュ状態の収得
  _IOCS a0,_SYS_STAT
  or.b d0,d2
  @@:
  lea (old_cache,pc),a0
  move.b (a0),d1  ;現在表示中の状態
  eor.b d2,d1
  beq update_cache_end  ;変化していない

  move.b  d2,(a0)

  moveq #$20,d0  ;大文字 <-> 小文字 変換用
  lea (cache,pc),a1
  tst.b d1
  bpl @f
    eor.b d0,(a1)  ;VENUS-X 二次キャッシュが変化した
  @@:
  lsr.b #1,d1
  bcc @f
    eor.b d0,(2,a1)  ;命令キャッシュ
  @@:
  lsr.b #1,d1
  bcc @f
    eor.b d0,(1,a1)  ;データキャッシュ
  @@:
  tst.b (a6)
  bpl update_cache_end  ;後でまとめて表示する

    moveq #X0+(cache-buf),d2  ;今すぐ表示する
    moveq #(cache_end-cache)-1,d4
    PUTMES
update_cache_end:
.endm


;割り込み使用状態の表示
; %ABCD_HORV
;  |||| |||+- V-DISP
;  |||| ||+-- Raster(CRTC-IRQ)
;  |||| |+--- OPM
;  |||| +---- H-SYNC
;  |||+------ Timer-D
;  ||+------- Timer-C
;  |+-------- Timer-B
;  +--------- Timer-A

.offset 0
  INT_A: .ds.b 1
  INT_B: .ds.b 1
  INT_C: .ds.b 1
  INT_D: .ds.b 1
  INT_H: .ds.b 1
  INT_O: .ds.b 1
  INT_R: .ds.b 1
  INT_V: .ds.b 1
.text

INT_CHG: .macro offs,char
  eori.b #char.eor.'_',(offs,a1)
.endm

UPDATE_INT: .macro
  lea (MFP),a0
  moveq #%1110_0001,d0
  moveq #%0111_1000,d1
  and.b (~MFP_IERA,a0),d0
  and.b (~MFP_IERB,a0),d1
  and.b (~MFP_IMRA,a0),d0  ;%HRA0_000B
  and.b (~MFP_IMRB,a0),d1  ;%0VCD_O000

  lea (old_int_a,pc),a0
  move.b (a0)+,d2  ;現在表示中の状態
  move.b (a0)+,d3  ;
  eor.b d0,d2
  eor.b d1,d3
  bne @f
    tst.b d2
    beq update_int_end  ;変化していない
  @@:
  move.b d1,-(a0)  ;新しい状態を保存
  move.b d0,-(a0)  ;

  lea (int,pc),a1
  lsr.b #1,d2  ;%0HRA_0000:B
  bcc @f
    INT_CHG INT_B,'B'
  @@:
  add.b d2,d2  ;%HRA0_0000
  bpl @f
    INT_CHG INT_H,'H'
  @@:
  add.b d2,d2  ;%RA00_0000
  bpl @f
    INT_CHG INT_R,'R'
  @@:
  add.b d2,d2  ;%A000_0000
  bpl @f
    INT_CHG INT_A,'A'
  @@:
  add.b d3,d3  ;%VCDO_0000
  bpl @f
    INT_CHG INT_V,'V'
  @@:
  add.b d3,d3  ;%CDO0_0000
  bpl @f
    INT_CHG INT_C,'C'
  @@:
  add.b d3,d3  ;%DO00_0000
  bpl @f
    INT_CHG INT_D,'D'
  @@:
  add.b d3,d3  ;%O000_0000
  bpl @f
    INT_CHG INT_O,'O'
  @@:
  tst.b (a6)
  bpl update_int_end  ;後でまとめて表示する

    moveq #X0+(int-buf),d2  ;今すぐ表示する
    moveq #(int_end-int)-1,d4
    PUTMES
update_int_end:
.endm


; (V)TwentyOne.sys オプションの表示
UPDATE_TWON: .macro
  .ifdef NO_SELF_REWRITE
    movea.l (twon_ptr,pc),a0
    move (a0),d0  ;現在のフラグ
  .else
    twon_ptr: .equ $+2
    move (0).l,d0
  .endif
  cmp (old_twon,pc),d0
  beq update_twon_end  ;変化していない

  lea (old_twon,pc),a0
  move (a0),d1
  move d0,(a0)  ;新しい状態を保存
  eor d0,d1

  lea (twon_list,pc),a0
  lea (twon,pc),a1
  lea (a1),a2
  moveq #(twon_end-twon)-1,d4
  update_twon_loop:
    move.b  (a0)+,d0
    add     d1,d1
    bpl     @f
      eor.b   d0,(a2)
    @@:
    addq.l  #1,a2
  dbra d4,update_twon_loop

  tst.b (a6)
  bpl update_twon_end  ;後でまとめて表示する

    moveq #X0+(twon-buf),d2  ;今すぐ表示する
    moveq #(twon_end-twon)-1,d4
    PUTMES
update_twon_end:
.endm


;PCM8 の動作モードの表示
UPDATE_PCM8: .macro
  lea (pcm8,pc),a1
  movea.l (TRAP2_VEC*4),a0
  moveq #3,d0
  cmpi.l #'PCM8',(-8,a0)
  bne @f  ;未常駐

    move #$1fc,d0  ;多重再生モードの収得
    moveq #-1,d1
    trap #2
@@:
  cmp.b (old_pcm8-pcm8,a1),d0
  beq update_pcm8_end  ;前回と同じ状態

    move.b d0,(old_pcm8-pcm8,a1)
    add d0,d0
    add d0,d0
    move.l (update_pcm8_mes-pcm8,a1,d0.w),(a1)

    tst.b (a6)
    bpl update_pcm8_end  ;後でまとめて表示する
      moveq #X0+(pcm8+1-buf),d2  ;今すぐ表示する
      moveq #(pcm8_end-(pcm8+1))-1,d4
      addq.l  #1,a1  ;':' は変わらないので飛ばす
      PUTMES
update_pcm8_end:
.endm


GETTIME_READ: .macro
  bsr gettime_read
  tst.b d1  ;1秒カウンタが0なら、途中でM9秒がN0秒に繰り上がった可能性がある
  bne @skip
    bsr gettime_read  ;M0秒からM1秒に繰り上がる可能性があるがそのままで問題ない
  @skip:
.endm

;RTCから時刻を読み取る
GETTIME_FROM_RTC: .macro
  lea (RTC_MODE),a1
  move.b (a1),d3
  bclr #0,d3
  beq @bank0  ;もともと BANK 0 なら切り替え不要
    move.b d3,(a1)  ;BANK 0 選択
    GETTIME_READ
    addq.b #1,d3
    move.b d3,(a1)  ;BANK 1 に戻す
    bra @end
  @bank0:
    GETTIME_READ
  @end:
.endm

;in a0.l RTC_MODE
;out d0.l 時刻データ $00_hh_mm_ss
gettime_read:
  lea (RTC_10HOUR+1-RTC_MODE,a1),a0
  moveq #$f,d0
  and -(a0),d0  ;10時間
  lsl #4,d0
  moveq #$f,d1
  and -(a0),d1  ;1時間
  or.b d1,d0
  swap d0
  moveq #$f,d1
  and -(a0),d1  ;10分
  move d1,d0
  .rept 3
    lsl #4,d0
    moveq #$f,d1
    and -(a0),d1  ;1分、10秒、1秒
    or.b d1,d0
  .endm
  rts

;時刻の表示
UPDATE_TIME: .macro skip_date_label
  GETTIME_FROM_RTC
  cmp.l (old_time,pc),d0
  beq skip_date_label  ;時刻が変わっていなければ日付の更新も不要

  lea  (time_end,pc),a1
  move.l (old_time-time_end,a1),d1  ;前回の時刻
  move.l d0,(old_time-time_end,a1)

  move.l d1,d2
  eor.l d0,d2
  moveq #'0',d5

  moveq #$f,d3
  and.b d0,d3
  add.b d5,d3
  move.b d3,-(a1)  ;一秒
  move.l a1,d4  ;d4 = time_end - 1
  lsr.l #4,d2
  beq update_time_write
  lsr.b #4,d0
  add.b d5,d0
  move.b d0,-(a1)  ;十秒
  lsr.l #4,d2
  beq update_time_write

  subq.l #1,a1  ;':'を飛ばす
  move d0,-(sp)
  moveq #$f,d3
  and.b (sp)+,d3
  add.b d5,d3
  move.b d3,-(a1)  ;一分
  rol #4,d0
  moveq #$f,d3
  and.b d0,d3
  add.b d5,d3
  move.b d3,-(a1)  ;十分
  lsr #8,d2
  beq update_time_write

  subq.l  #1,a1  ;':'を飛ばす
  swap d0
  moveq #$f,d3
  and.b d0,d3
  add.b d5,d3
  move.b d3,-(a1)  ;一時
  lsr.b #4,d0
  add.b d5,d0
  move.b d0,-(a1)  ;十時
update_time_write:
  tst.b (a6)
  bpl update_time_end  ;後でまとめて表示する

    sub.l a1,d4  ;今すぐ表示する
    moveq #X0+(time_end-buf)-1,d2
    sub.l d4,d2
    PUTMES
update_time_end:
.endm


;時刻を取得後または日付の取得中に日付が変わった場合、時刻が(前日の)23:59:59のまま
;表示されてしまうので厳密に言うと問題があるが、すぐに更新されるのでよしとする。
GETDATE_READ: .macro
  bsr getdate_read
  tst.b d1  ;1日カウンタが0なら、途中でM9日がN0日に繰り上がった可能性がある
  beq @reload
  cmpi.b #1,d0  ;01日なら、途中で28～31日が翌月01日に変わった可能性がある
  bne @skip
    @reload:          ;M0日からM1日に繰り上がる可能性があるがそのままで問題ない
    bsr getdate_read  ;01日が02日に代わる可能性があるがそのままで問題ない
  @skip:
.endm

;RTCから日時を読み取る
GETDATE_FROM_RTC: .macro
  lea (RTC_MODE),a1
  move.b (a1),d3
  bclr #0,d3
  beq @bank0  ;もともと BANK 0 なら切り替え不要
    move.b d3,(a1)  ;BANK 0 選択
    GETDATE_READ
    addq.b #1,d3
    move.b d3,(a1)  ;BANK 1 に戻す
    bra @end
  @bank0:
    GETDATE_READ
  @end:
.endm

;in a0.l RTC_MODE
;out d0.l 日付データ $0w_yy_mm_dd
getdate_read:
  lea (RTC_10YEAR+1-RTC_MODE,a1),a0
  moveq #$f,d0
  and (RTC_DAY+1-RTC_MODE,a1),d0
  .rept 2
    lsl #4,d0
    moveq #$f,d1
    and -(a0),d1  ;10年、1年
    or.b d1,d0
  .endm
  swap d0
  moveq #$f,d1
  and -(a0),d1  ;10月
  move d1,d0
  .rept 3
    lsl #4,d0
    moveq #$f,d1
    and -(a0),d1  ;1月、10日、1日
    or.b d1,d0
  .endm
  rts

;日付の表示
UPDATE_DATE: .macro
  GETDATE_FROM_RTC
  lea (old_date,pc),a0
  cmp.l (a0),d0
  beq update_date_time_end  ;日付は変わってない

  move.l d0,(a0)

  lea (date_,pc),a1
  lea (a1),a2
  move.b #'2',(a2)+  ;'2000-00-00('
  move.l #'000'<<8+DATE_SEP,(a2)+
  move.l #'00'<<16+DATE_SEP<<8+'0',(a2)+
  move #'0(',(a2)+

  moveq #0,d1
  move.b (a0),d1  ;曜日
  add d1,d1
  move (day_table-date_,a1,d1.w),(a2)

  swap d0  ;BCD 形式の西暦を補正
  subi.b #$20,d0  ;$20～$99 -> 2000～2079
  bcc @f
    addi.b #$80+$20,d0  ;$00～$19 -> 1980～1999
    subq.b #1,(a1)
    move.b #'9',(1,a1)
  @@:
  swap d0

  moveq #3-1,d2  ;日付/月/年を文字列化
  update_date_loop:
    subq.l #1,a2
    moveq #$f,d1
    and.b d0,d1
    add.b d1,-(a2)  ;一の位
    lsr.b #4,d0
    add.b d0,-(a2)  ;十の位
    lsr.l #8,d0
  dbra d2,update_date_loop

  tst.b (a6)
  bpl update_date_end  ;後でまとめて表示する

    moveq #X0+(date_-buf),d2  ;今すぐ表示する
    moveq #(date_end-date_)-1,d4
    PUTMES
update_date_end:
.endm


;表示ルーチン
;in a6.l first_flag
;break d0-d6/a0-a4

PUTMES: .macro
  move ((color-1)-first_flag,a6),d1
  moveq #31,d3
  _IOCS a0,_B_PUTMES
.endm

hex_table: .dc.b '0123456789abcdef'
.even

update_line:
  UPDATE_ECODE
  UPDATE_CACHE
  UPDATE_INT
  UPDATE_TWON
  UPDATE_PCM8
  UPDATE_TIME update_date_time_end
  UPDATE_DATE
  update_date_time_end:

  tst.b (a6)  ;first_flag
  bmi @f  ;各ルーチンごとに表示した
    st (a6)
    moveq #X0,d2  ;最後にまとめて表示する
    moveq #(WIDTH-X0)-1,d4
    lea (buf,pc),a1
    PUTMES
  @@:
  rts


;ファンクションキー行消去
;in d1.b ファンクションキー行表示モード
;
;1. RTC 16Hz 割り込みを禁止する
;2. ファンクションキー行を消去する
;3. first_flag を初期化する
;4. active_flag を false にする
;
;;L00fd26:
;;  PUSH d0-d5/a1
;;  move.b d1,(L013a40)
;;  lea (L00fd58),a1  ;-> jmp (fncclr_job)
fncclr_job:
  bsr rtc_int_disable

  subq.b #2,d1  ;表示モードなら消去しない
  bcs fncclr_job_skip
    PUSH a0/a2-a5
    moveq #0,d1
    moveq #0,d2
    moveq #0,d3
    moveq #0,d4
    movea.l d1,a1
    movea.l d1,a2
    movea.l d1,a3
    movea.l d1,a4
    lea (CRTC_R21),a5
    movea.l (TXTADR),a0
    move (a5),d5
    moveq #1,d0
    swap d0  ;128*16*32
    adda.l d0,a0
    move #$133,(a5)  ;同時アクセス
    moveq #(128*16)/(4*8)/2-1,d0
    @@:
      movem.l d1-d4/a1-a4,-(a0)  ;ファンクションキー行を消去
      movem.l d1-d4/a1-a4,-(a0)
    dbra d0,@b
    move d5,(a5)
    POP a0/a2-a5
  fncclr_job_skip:
  lea (first_flag,pc),a1
  clr.b (a1)
  clr.b (active_flag-first_flag,a1)
  POP d0-d5/a1
  rts


;漢字変換用ウィンドウオープン
;break a1
hendsp0_job:
  bsr rtc_int_disable  ;元の処理を呼び出す
  lea  (first_flag,pc),a1
  clr.b (a1)
  jmp ($ff52)


;ファンクションキー行描画
;
;1. DOS _CONCTRL(16)の処理で呼び出された時は first_flag を初期化する
;2. active_flag を true にする
;3. RTC 16Hz 割り込みを許可する
;
;;L00fe20:
;;  PUSH d0/a6
;;  cmpi.b #3,(L013a40)  ;-> cmpi.b #2,…
;;  beq L00fe50          ;-> bcc …
;;  lea (L013a42),a6     ;-> jmp (fncdisp_job)
fncdisp_job:
  move.l a1,a6
  lea (first_flag,pc),a1
  cmpi.l #HUMAN302_FNCRET,(8,sp)
  bne @f
    clr.b (a1)
  @@:
  st (active_flag-first_flag,a1)
  bsr rtc_int_enable
  movea.l a6,a1
  POP d0/a6
  rts


;漢字変換用ウィンドウクローズ
;break a1
hendsp3_job:
  jsr ($ffa8)  ;元の処理を呼び出す
  move.l d0,d7
  move.b (active_flag,pc),d0
  beq @f
    bsr rtc_int_enable
  @@:
  move.l d7,d0
  rts


;RTC の割り込みを許可する
;break d0/a1
rtc_int_enable:
  lea (RTC+~RTC_MODE),a1
  moveq #%1000,d0
  move.b d0,(a1)  ;アラーム動作禁止
  move.b d0,(~RTC_RESET-~RTC_MODE,a1)  ;16Hz 出力オン

  lea (tma_int_job,pc),a1
  cmpa.l (TIMERA_VEC*4),a1
  bne @f
    moveq #%0010_0000,d0 ;Timer-A 割り込み許可
    or.b d0,(MFP_IERA)
    or.b d0,(MFP_IMRA)
  @@:
  rts


;RTC の割り込みを禁止する
;break d0
rtc_int_disable:
  lea (RTC+~RTC_MODE),a1
  move.b #%1000,(a1)  ;アラーム動作禁止
  move.b #%1100,(~RTC_RESET-~RTC_MODE,a1)  ;1Hz/16Hz 出力オフ

  lea (tma_int_job,pc),a1
  cmpa.l (TIMERA_VEC*4),a1
  bne @f
    andi.b #%1101_1111,(MFP_IERA)  ;Timer-A 割り込み禁止
  ;;andi.b #%1101_1111,(MFP_IMRA)
  @@:
  rts


.quad
update_pcm8_mes:
  .dc.l ':off'
  .dc.l ':on '
  .dc.l ':fnc'
  .dc.l ':___'
day_table:
  .dc '日月火水木金土'


;ワーク/バッファ
.quad
.ifdef NO_SELF_REWRITE
  twon_ptr: .dc.l 0  ;フラグアドレス
.endif
old_time:  .dc.l -1
old_date:  .dc.l -1
old_ecode: .dc 0
old_twon:  .dc 1<<(_TWON_T_BIT-16)

cache_type: .dc.b 0  ;┌ 実装されているキャッシュの種類
old_cache:  .dc.b 0  ;└ 前回表示した時の状態
old_int_a:  .dc.b 0  ;┌ 前回表示した時の状態(IERA & IMRA)
old_int_b:  .dc.b 0  ;└                     (IERB & IMRB)
old_pcm8:   .dc.b -1

;.even ;injob_flag を必ず奇数アドレスにする
;.dc.b 0
injob_flag:  .dc.b 0   ;┌ 順番を変えないこと
first_flag:  .dc.b 0   ;│
color:       .dc.b -1  ;└
active_flag: .dc.b -1

twon_list:
  .irpc char,'CSPTFRWYA'
    .dc.b '&char'.eor.'_'
  .endm

.even
buf:            .dc.b ' $'
ecode:          .dc.b   '0   '
ecode_end:      .dc.b ' mpu:680'  ;MPU/Clock は固定
mpu:            .dc.b         '00'
mhz:            .dc.b           '(00MHz)'
;;              .dc.b           '@000MHz'
                .dc.b ' cache:'
cache:          .dc.b        '___'  ;VDI
cache_end:      .dc.b ' int:'
int:            .dc.b      '________'  ;ABCDHORV
int_end:        .dc.b ' twon:'
twon:           .dc.b        '_________'  ;CSPTFRWYA
twon_end:       .dc.b ' pcm8'
pcm8:           .dc.b ':___'  ;on /off/fnc
pcm8_end:       .dc.b ' '
date_:          .dc.b '0000',DATE_SEP,'00',DATE_SEP,'00(__'
date_end:       .dc.b ') '  ;年月日(曜日)
time:           .dc.b '00:00:00'  ;時刻
time_end:
buf_end:        .dc.b 0,0
.even


;非常駐部
keep_end:

;バッファ初期化
init_buf:
  PUSH d0-d2/a0-a1

;終了コード なし

;MPU の種類
  lea (mpu,pc),a0
  move.b (MPUTYPE),d2
  add.b d2,(a0)  ;680x0

;MPU の動作周波数
  subq.b #2,d2
  bcc int_buf_mhz_030

  move (ROMCNT),d0
  mulu #10+2,d0  ;dbra+wait
  moveq #50,d1
  add.l d1,d0
  divu #100,d0
  bra @f
  int_buf_mhz_030:
    moveq #0,d1
    IOCS _SYS_STAT
    swap d0
  @@:
  moveq #0,d1
  not d1
  and.l d1,d0  ;clock(MHz)*10
  divu #10,d0
  and.l d1,d0  ;clock(MHz)
  addq.l #mhz-mpu,a0
  cmpi #99,d0
  bls int_buf_mhz_normal

    move.b #'@',(a0)+  ;@xxxMHz
    divu #100,d0
    add.b d0,(a0)+  ;100の位
    swap d0
    and.l d1,d0
    divu #10,d0
    add.b d0,(a0)+  ;10の位
    swap d0
    addi.b #'0',d0
    move.b d0,(a0)+  ;1の位
    move.l #'MHz ',(a0)
    bra @f
  int_buf_mhz_normal:
    addq.l #1,a0 ;move.b #'(',(a0)+
    divu #10,d0
    add.b d0,(a0)+  ;xxMHz
    swap d0
    add.b d0,(a0)+
  @@:

;実装されているキャッシュ
  tst.b d2  ;d2.b = MPUTYPE-2
  smi d1
  ble @f                   ;68000-010 = %00
    addq.b #1<<CACHE_D,d1  ;68020     = %01
  @@:
  addq.b  #1<<CACHE_I,d1   ;68030-060 = %11

  bsr is_exist_venus_x
  lsl.b #CACHE_V,d0
  or.b d0,d1
  lea (cache,pc),a0
  move.b d1,(cache_type-cache,a0)
  bpl @f
    move.b #'v',(a0)  ;VENUS-X 二次キャッシュ
  @@:
  lsr.b #1,d1
  bcc @f
    move.b #'i',(2,a0)  ;命令キャッシュ
  @@:
  lsr.b #1,d1
  bcc @f
    move.b #'d',(1,a0)  ;データキャッシュ
  @@:

;割り込み なし

;TwentyOne
  lea (old_twon,pc),a1
  clr -(sp) ;_TWON_GETID
  DOS _TWON ;識別子の収得
  cmpi.l #_TWON_ID,d0
  bne int_buf_no_twon  ;(V)TwentyOne.sys が組み込まれていない

    addq #_TWON_GETADR,(sp)
    DOS _TWON  ;フラグアドレスの収得
    tst.l d0
    bmi int_buf_no_twon  ;念の為…

      movea.l d0,a1
  int_buf_no_twon:
  move.l a1,(twon_ptr-cache,a0)
  addq.l #2,sp
;NO_SELF_REWRITE 未定義時はあとで命令キャッシュを破棄しておくこと

;PCM8 なし

;日付 なし

;時刻 なし

  POP  d0-d2/a0-a1
  rts


;初期化
start3:
  lea (color,pc),a6
  moveq #0,d5  ;d5.l = -1 -> -a
  moveq #0,d6  ;d6.hw = $ffff -> -n
               ;d6.lw = $ffff -> -q
  moveq #0,d7  ;1=on -1=off

  lea (GetArgChar,pc),a4
  GETARGCHAR: .macro
    jsr (a4)
  .endm

  pea (1,a2)
  bsr GetArgCharInit
  addq.l #4,sp
  arg_next:
    GETARGCHAR
  arg_next2:
    tst.l d0
    beq arg_next
    bmi arg_end

    cmpi.b #'-',d0
    beq arg_option
    cmpi.b #'o',d0
    bne arg_error

    moveq #1,d7  ;on
    GETARGCHAR
    cmpi.b #'n',d0
    beq arg_on
    moveq #'f',d1
    cmp.b d0,d1
    bne arg_error
    ;arg_off:
    GETARGCHAR
    cmp.b d0,d1
    bne arg_error
      moveq #-1,d7  ;off
    arg_on:
      GETARGCHAR
      tst.b d0
      beq arg_next2
      bra arg_error

  arg_option:
    GETARGCHAR
    cmpi.b #'-',d0
    beq long_option  ;--long-option
  arg_option_loop:
    cmpi.b #'?',d0
    beq print_usage
    ori.b #$20,d0
    cmpi.b #'c',d0
    beq change_color
    cmpi.b #'h',d0
    beq print_usage
    cmpi.b #'a',d0
    beq option_a
    cmpi.b #'n',d0
    beq option_n
    cmpi.b #'q',d0
    beq option_q
    cmpi.b #'r',d0
    beq release
    cmpi.b #'v',d0
    beq print_version
    bra arg_error
  arg_option_next:
    GETARGCHAR
  arg_option_next2:
    tst.b d0
    bne arg_option_loop
    bra arg_next2

;-a Timer-A 割り込みを使用する
option_a:
  not.l d5
  bra arg_option_next

;-n ファンクションキー行を再描画しない
option_n:
  not.l d6  ;not.hw d6
;-q メッセージ抑制
option_q:
  not d6
  bra arg_option_next

;--quiet メッセージ抑制
longopt_quiet:
  not d6
  bra arg_next

;-c<n> 表示色指定
change_color:
  moveq #9,d3

  GETARGCHAR
  moveq #-'0',d2
  add.b d0,d2  ;一桁目
  cmp.b d3,d2
  bhi change_color_error

  change_color_loop:
    GETARGCHAR
    moveq #-'0',d1
    add.b d0,d1
    cmp.b d3,d1
    bhi change_color_end

    mulu #10,d2
    add.b d1,d2
    cmpi.b #COLOR_MAX,d2
    bls change_color_loop
  change_color_error:
    bra arg_error
  change_color_end:
    move.b d2,(a6)  ;color
    bra arg_option_next2

;--quiet, --release
;--help, --version
long_option:
  subq.l #LONGOPT_MAX+1,sp
  lea (sp),a0
  moveq #LONGOPT_MAX,d1
  get_long_opt_loop:
    GETARGCHAR
    move.b d0,(a0)+
  dbeq d1,get_long_opt_loop
  bne arg_error  ;長すぎる

  lea (long_opt_tbl,pc),a0
  long_opt_cmp_loop:
    tst (a0)
    beq arg_error  ;存在しないオプション
    lea (a0),a1
    adda (a0)+,a1  ;文字列のアドレス
    lea (a0),a3
    adda (a0)+,a3  ;処理アドレス
    lea (sp),a2
  @@:
    cmpm.b (a1)+,(a2)+  ;文字列比較
    bne long_opt_cmp_loop
    tst.b (-1,a1)
  bne @b
  jmp (a3)

LONGOPT: .macro str,job
  .dc str-$,job-$
.endm
long_opt_tbl:
  LONGOPT str_help,   print_usage
  LONGOPT str_quiet,  longopt_quiet
  LONGOPT str_release,release
  LONGOPT str_version,print_version
  .dc 0

arg_end:
  bra keep  ;常駐


;常駐
keep:
  .ifndef UNIX_STYLE
    tst d6
    bmi @f
      bsr print_title
    @@:
  .endif
  clr.l -(sp)
  DOS _SUPER

  bsr keep_check
  bmi version_error   ;常駐部のバージョンが違う
  bne already_keeped  ;既に常駐している

  lea (keep_start,pc),a5  ;patch_on 用

  DOS _VERNUM
  cmpi #$0302,d0
  bne hu_ver_error  ;Human68k のバージョンが未対応

  bsr patch_check_orig
  bne patch_error  ;パッチがあてられない

;常駐処理
  tst.b (a6)  ;color
  bpl @f
    move.b #DEFAULT_COLOR,(a6)
  @@:
  bsr init_buf

  PUSH_SR_DI
  bsr force_patch
  tst.l d7
  bmi @f  ;off の時はパッチをあてない
    bsr patch_on
  @@:
  ;;POP_SR

;割り込み設定
  ;;PUSH_SR_DI
  lea (old_rtc_vec,pc),a0
  move.l d5,(a0)
  beq keep_rtc_only  ;-a なし
    move.l (TIMERA_VEC*4),(a0)
    suba.l a1,a1
    IOCS _TIMERAST
    moveq #$00_04,d1
    lea (tma_int_job,pc),a1
    IOCS _TIMERAST
  keep_rtc_only:

  lea (old_rtc_vec,pc),a0
  move.l (RTC1HZ_VEC*4),(a0)
  lea (rtc_int_job,pc),a0
  move.l a0,(RTC1HZ_VEC*4)
  move.l d7,d0
  bsr rtc_int_reset
  bsr mfp_int_enable
  POP_SR

  bsr redraw_fnckey

;メッセージを表示して常駐終了
  pea (keep_mes,pc)
  bsr print_message
  addq.l #4,sp

  clr -(sp)
  pea (keep_end-keep_start).w
  DOS _KEEPPR


;既に常駐していれば、on/off の変更と MFP/RTC の再設定を行う
already_keeped:
  movea.l d0,a5

  PUSH_SR_DI
  move.l d7,d4
  bmi already_keeped_off
  bgt already_keeped_on

    bsr patch_check_orig
    bne @f
      moveq #-1,d4  ;off になっているので RTC 割り込み禁止
      bra @f
  already_keeped_on:
  bsr patch_check_orig
  bne @f ;既に on になっている
    bsr patch_on
    bra @f
  already_keeped_off:
  bsr patch_check
  bne @f  ;既に off になっている
    bsr patch_off
  @@:
  ;;POP_SR

  ;;PUSH_SR_DI
  move.b (a6),d0
  bmi @f  ;-c<n> は指定されてない
    cmp.b (color-keep_start,a5),d0
    beq @f
      move.b d0,(color-keep_start,a5)  ;表示色変更
      clr.b (first_flag-keep_start,a5)
  @@:
  move.l d4,d0
  bsr rtc_int_reset
  bsr mfp_int_enable
  POP_SR

  bsr redraw_fnckey

;メッセージを表示して終了
  lea (rtc_init_mes,pc),a0
  tst.l d7  ;on/off 指定
  beq @f
    lea (on_mes,pc),a0
    bpl @f
      lea (off_mes,pc),a0
  @@:
  pea (a0)
print_and_exit:
  bsr print_message
  addq.l #4,sp
  DOS _EXIT


;MFP の割り込みを許可する
;break d0/a1
mfp_int_enable:
  lea (MFP+~MFP_IMRB),a1
  moveq #$01,d0
  or.b d0,(a1)                      ;割り込み許可
  or.b d0,(~MFP_IERB-~MFP_IMRB,a1)  ;〃
  rts


;RTC の割り込みを再設定する
;in d0.l 0:無指定 1:on -1:off
;break d0/a1
rtc_int_reset:
  tst.l d0
  bmi rtc_int_disable2  ;off なら常に禁止

  move.l #14<<16+$ffff,-(sp)
  DOS _CONCTRL
  addq.l #4,sp
  subq.l #2,d0
  bcc rtc_int_disable2  ;無表示なら禁止
  bra rtc_int_enable2   ;表示中なら許可


;RTC の割り込みを許可する
;break d0/a1
rtc_int_enable2:
  lea (RTC+~RTC_MODE),a1
  moveq #%1000,d0
  move.b d0,(a1)  ;アラーム動作禁止
  move.b d0,(~RTC_RESET-~RTC_MODE,a1)  ;16Hz 出力オン

  lea (tma_int_job-keep_start,a5),a1
  cmpa.l (TIMERA_VEC*4),a1
  bne @f
    moveq #%0010_0000,d0  ;Timer-A 割り込み許可
    or.b d0,(MFP_IERA)
    or.b d0,(MFP_IMRA)
  @@:
  rts


;RTC の割り込みを禁止する
;break a1
rtc_int_disable2:
  lea (RTC+~RTC_MODE),a1
  move.b #%1000,(a1)  ;アラーム動作禁止
  move.b #%1100,(~RTC_RESET-~RTC_MODE,a1)  ;1Hz/16Hz 出力オフ

  lea (tma_int_job-keep_start,a5),a1
  cmpa.l (TIMERA_VEC*4),a1
  bne @f
    andi.b  #%1101_1111,(MFP_IERA)  ;Timer-A 割り込み禁止
    ;;andi.b  #%1101_1111,(MFP_IMRA)
  @@:
  rts


;ファンクションキー行を再描画する
;in d6.hw $ffff なら再描画しない
;break d0
redraw_fnckey:
  tst.l d6
  bmi redraw_fnckey_end
    move.l #14<<16+$ffff,-(sp)
    DOS _CONCTRL
    move d0,(2,sp)  ;現在のモードに再設定
    DOS _CONCTRL
    addq.l #4,sp
  redraw_fnckey_end:
  rts


;常駐解除
release:
  .ifndef UNIX_STYLE
    tst d6
    bmi @f
      bsr print_title
    @@:
  .endif
  clr.l -(sp)
  DOS _SUPER

  bsr keep_check
  bmi version_error     ;常駐部のバージョンが違う
  beq not_keeped_error  ;常駐していない
  movea.l d0,a5

;常駐解除処理
  bsr patch_check_orig
  beq @f
    bsr patch_check
    bne patch_error
      PUSH_SR_DI
      bsr patch_off
      POP_SR
  @@:
;割り込み解除
  tst.l (old_rtc_vec-keep_start,a5)
  beq release_rtc_only  ;-a なし
    suba.l a1,a1
    IOCS _TIMERAST
    move.l (old_rtc_vec-keep_start,a5),(TIMERA_VEC*4)
  release_rtc_only:

  PUSH_SR_DI
  bsr rtc_int_disable2
  bsr mfp_int_disable
  move.l (old_rtc_vec-keep_start,a5),(RTC1HZ_VEC*4)
  POP_SR

  pea (-$f0,a5)  ;常駐部のメモリを解放
  DOS _MFREE
  addq.l  #4,sp

  bsr redraw_fnckey

;メッセージを表示して終了
  pea (release_mes,pc)
  bra print_and_exit


;MFP の割り込みを禁止する
;break d0/a1
mfp_int_disable:
  lea (MFP+~MFP_IMRB),a1
  moveq #$fe,d0
  and.b d0,(a1)                      ;割り込み禁止
  and.b d0,(~MFP_IERB-~MFP_IMRB,a1)  ;〃
  rts


;常駐検査
;out d0.l 0:未常駐
;         -1:常駐部のバージョンが違う
;         それ以外:常駐部の keep_start のアドレス
;    ccr <tst.l d0> の結果
;注意: スーパバイザモードで呼び出すこと
keep_check:
  PUSH d1/a0-a1
  movea.l (RTC1HZ_VEC*4),a0
  lea (keep_id-rtc_int_job,a0),a0
  lea (keep_id,pc),a1
  moveq #0,d0
  cmpm.l (a0)+,(a1)+  ;識別子１
  bne @f
  cmpm.l (a0)+,(a1)+  ;識別子２
  bne @f
  moveq #-1,d0
  cmpm.l (a0)+,(a1)+  ;バージョン
  bne @f
    lea (keep_start-rtc_int_job,a0),a0
    move.l a0,d0  ;常駐部のアドレスを返す
  @@:
  tst.l d0
  POP d1/a0-a1
  rts


;Human68k へのパッチ

;パッチをあてたい所が書き換えられていないか調べる
;out a1.l パッチアドレス 1
;    a2.l 〃             2
;    a3.l 〃             3
;    ccr  Z=1:OK Z=0:error
patch_check_orig:
  lea (HUMAN302_FNCCLR),a1
  lea (HUMAN302_FNCDISP-HUMAN302_FNCCLR,a1),a2
  lea (HUMAN302_HENDSP0-HUMAN302_FNCCLR,a1),a3
  cmpi #$43f9,(a1)+
  bne @f
  cmpi.l #$fd58,(a1)
  bne @f
  cmpi #$4df9,(a2)+
  bne @f
  cmpi.l #$0001_3a42,(a2)
  bne @f
  cmpi.l #$ff52,(a3)
  bne @f
  cmpi.l #$ffa8,(HUMAN302_HENDSP3-HUMAN302_HENDSP0,a3)
@@:
  rts


;パッチをあてた所が書き換えられていないか調べる
;in a5.l 常駐部の keep_start
;out a1.l パッチアドレス 1
;    a2.l 〃             2
;    a3.l 〃             3
;    ccr  Z=1:OK Z=0:error
;break a0
patch_check:
  lea (HUMAN302_FNCCLR),a1
  lea (HUMAN302_FNCDISP-HUMAN302_FNCCLR,a1),a2
  lea (HUMAN302_HENDSP0-HUMAN302_FNCCLR,a1),a3
  cmpi #JMP_ABSL_CODE,(a1)+
  bne @f
  lea (fncclr_job-keep_start,a5),a0
  cmpa.l (a1),a0
  bne @f
  cmpi #JMP_ABSL_CODE,(a2)+
  bne @f
  lea (fncdisp_job-keep_start,a5),a0
  cmpa.l (a2),a0
  bne @f
  lea (hendsp0_job-keep_start,a5),a0
  cmpa.l (a3),a0
  bne @f
  lea (hendsp3_job-keep_start,a5),a0
  cmpa.l (HUMAN302_HENDSP3-HUMAN302_HENDSP0,a3),a0
@@:
  rts


;パッチをあてる
;in a1.l パッチアドレス 1
;   a2.l 〃             2
;   a3.l 〃             3
;   a5.l 常駐部または自分自身の keep_start
;break a0-a3
patch_on:
  lea (fncclr_job-keep_start,a5),a0
  move.l a0,(a1)
  move #JMP_ABSL_CODE,-(a1)
  lea (fncdisp_job-keep_start,a5),a0
  move.l a0,(a2)
  move #JMP_ABSL_CODE,-(a2)
  lea (hendsp0_job-keep_start,a5),a0
  move.l a0,(a3)
  lea (hendsp3_job-keep_start,a5),a0
  move.l a0,(HUMAN302_HENDSP3-HUMAN302_HENDSP0,a3)
  bra flush_mpu_cache
;;rts


;Human68k 内部へのパッチを戻す
;in a1.l パッチアドレス 1
;   a2.l 〃             2
;   a3.l 〃             3
;break a1-a3
patch_off:
  move.l #$fd58,(a1)
  move #$43f9,-(a1)
  move.l #$0001_3a42,(a2)
  move #$4df9,-(a2)
  move.l #$ff52,(a3)
  move.l #$ffa8,(HUMAN302_HENDSP3-HUMAN302_HENDSP0,a3)
  bra flush_mpu_cache
;;rts


;常駐時にあてて、常駐解除時もそのまま残しておくパッチ
force_patch:
  move #2,(HUMAN302_FNCPAT1)
  move.b #BCC_CODE>>8,(HUMAN302_FNCPAT2)
  bra flush_mpu_cache
;;rts


;サブルーチン

;MPU の命令キャッシュを破棄する
flush_mpu_cache:
  cmpi.b #2,(MPUTYPE)
  bcs @f
    PUSH d0-d1
    moveq #3,d1
    IOCS _SYS_STAT
    POP d0-d1
  @@:
  rts


print_title:
  pea (title_mes,pc)
  DOS _PRINT
  addq.l #4,sp
  rts

print_message:
  tst d6
  bmi @f
    .ifdef UNIX_STYLE
      pea (header_mes,pc)
      DOS _PRINT
      move.l (8,sp),(sp)
    .else
      move.l (4,sp),-(sp)
    .endif
    DOS _PRINT
    addq.l #4,sp
  @@:
  rts


;VENUS-X が存在するか調べる
;out d0.l 0:なし 1:あり
;    ccr  <tst.l d0> の結果
is_exist_venus_x:
  move.l a0,-(sp)
  lea (XT30_IO3),a0
  bsr check_bus_error_long
  beq is_exist_vx_false  ;Xellent30 が存在すれば VENUS-X は無し

  lea (VX_CTRL-XT30_IO3,a0),a0
  bsr check_bus_error_long  ;制御レジスタ
  bne is_exist_vx_false
    .irp    id,'V','X'
      addq.l #4,a0
      bsr check_bus_error_long  ;ID 1/2
      bne is_exist_vx_false
      cmpi.b #id,d0
      bne is_exist_vx_false
    .endm
    moveq #1,d0
is_exist_vx_end:
  movea.l (sp)+,a0
  rts
is_exist_vx_false:
  moveq #0,d0
  bra is_exist_vx_end


;指定アドレスを読みこんでバスエラーが発生するか調べる
;in a0.l アドレス
;out d0.bwl 読み込んだデータ
;    ccr    Z=1:正常終了 Z=0:バスエラーが発生した
check_bus_error_long:
  move #4,-(sp)
  subq.l #4,sp
  move.l sp,(sp)
  move.l a0,-(sp)
  DOS _BUS_ERR
  move.l d0,(sp)
  move.l (4,sp),d0
  tst.l (sp)+
  addq.l #10-4,sp
  rts


;エラー処理

print_version:
  lea (ver_mes_end,pc),a0
  .ifdef __CRLF__
    move.b #CR,(a0)+
  .endif
  move.b #LF,(a0)+
  clr.b (a0)
  bsr print_title
  DOS _EXIT

print_usage:
  bsr print_title
  pea (usage_mes,pc)
  DOS _PRINT
  addq.l #8,sp
  DOS _EXIT

arg_error:
  .ifndef UNIX_STYLE
    bsr print_title
  .endif
  lea (arg_err_mes,pc),a0
  bra error_exit
hu_ver_error:
  lea (huver_err_mes,pc),a0
  bra error_exit
patch_error:
  lea (patch_err_mes,pc),a0
  bra error_exit
version_error:
  lea (ver_err_mes,pc),a0
  bra error_exit
not_keeped_error:
  lea (nokeep_err_mes,pc),a0
  bra error_exit

error_exit:
  move #2,-(sp)  ;STDERR
  .ifdef UNIX_STYLE
    pea (header_mes,pc)
    DOS _FPUTS
    move.l a0,(sp)
  .else
    pea (a0)
  .endif
  DOS _FPUTS
  addq.l #6,sp

  move #1,-(sp)
  DOS _EXIT2


;HUPAIR Decoder
.if 0
  GetArgChar_p: .dc.l 0
  GetArgChar_c: .dc.b 0
  .even
.else
  GetArgChar_p: .equ GetArgCharInit
  GetArgChar_c: .equ GetArgCharInit+4
.endif

GetArgChar:
  movem.l d1/a0-a1,-(sp)
  moveq #0,d0
  lea (GetArgChar_p,pc),a0
  movea.l (a0)+,a1
  move.b (a0),d0
  bmi GetArgChar_noarg
GetArgChar_quate:
  move.b d0,d1
GetArgChar_next:
  move.b (a1)+,d0
  beq GetArgChar_endarg
  tst.b d1
  bne GetArgChar_inquate
  cmpi.b #' ',d0
  beq GetArgChar_separate
  cmpi.b #"'",d0
  beq GetArgChar_quate
  cmpi.b #'"',d0
  beq GetArgChar_quate
GetArgChar_end:
  move.b d1,(a0)
  move.l a1,-(a0)
GetArgChar_abort:
  movem.l (sp)+,d1/a0-a1
  rts
GetArgChar_endarg:
  st (a0)
  bra GetArgChar_abort
GetArgChar_noarg:
  moveq #1,d0
  ror.l #1,d0
  bra GetArgChar_abort

GetArgChar_inquate:
  cmp.b d0,d1
  bne GetArgChar_end
  clr.b d1
  bra GetArgChar_next

GetArgChar_separate:
  cmp.b (a1)+,d0
  beq GetArgChar_separate
  moveq #0,d0
  tst.b -(a1)
  beq GetArgChar_endarg
  bra GetArgChar_end

GetArgCharInit:
  movem.l a0-a1,-(sp)
  movea.l (12,sp),a1
GetArgCharInit_skip:
  cmpi.b #' ',(a1)+
  beq GetArgCharInit_skip
  tst.b -(a1)
  lea (GetArgChar_c,pc),a0
  seq (a0)
  move.l a1,-(a0)
  movem.l (sp)+,a0-a1
  rts


;データ類
.data

title_mes:   .dc.b program,' ',version
ver_mes_end: .dc.b '  ',date,' ',author,'.'
crlf_mes:    .dc.b CRLF,0

usage_mes:
  .dc.b 'usage: ',program,' [option] [on|off]',CRLF
  .dc.b 'option:',CRLF
  .dc.b '  -a             Timer-Aを使用する(EX68用)',CRLF
  .dc.b '  -c<n>          表示色指定(n=1～15)',CRLF
  .dc.b '  -n             ファンクションキー行を再描画しない',CRLF
  .dc.b '  -q             メッセージ抑制',CRLF
  .dc.b '  -r, --release  常駐解除',CRLF
  .dc.b '  on / off       動作を再開する / 一時停止する',CRLF
  .dc.b 0

.ifdef UNIX_STYLE
  header_mes: .dc.b program,': ',0
.endif

keep_mes:       .dc.b '常駐しました。',CRLF,0
release_mes:    .dc.b '常駐解除しました。',CRLF,0
rtc_init_mes:   .dc.b 'MFP/RTC の設定を初期化しました。',CRLF,0
on_mes:         .dc.b '動作を再開します。',CRLF,0
off_mes:        .dc.b '動作を停止します。',CRLF,0

arg_err_mes:    .dc.b '引数が正しくありません。',CRLF,0
huver_err_mes:  .dc.b 'Human68k version 3.02 以外では使用できません。',CRLF,0
patch_err_mes:  .dc.b 'Human68k パッチ部分が書き換えられています。',CRLF,0
ver_err_mes:    .dc.b '常駐部のバージョンが違います。',CRLF,0
nokeep_err_mes: .dc.b '常駐していません。',CRLF,0

;追加する場合は long_opt_tbl も変更すること
str_help:    .dc.b 'help',0
str_quiet:   .dc.b 'quiet',0
str_release: .dc.b 'release',0
str_version: .dc.b 'version',0
;                   1234567
LONGOPT_MAX: .equ 7


.end start
