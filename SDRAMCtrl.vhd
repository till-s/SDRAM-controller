-- Copyright Till Straumann, 2024. Licensed under the EUPL-1.2 or later.
-- You may obtain a copy of the license at
--   https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
-- This notice must not be removed.

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;
use     ieee.math_real.all;

use     work.SDRAMCtrlPkg.all;

entity SDRAMCtrl is
   generic (
      -- Actual clock frequency the device is operated at
      -- It is important to provide the real clock frequency
      -- the device is operated at in order to compute the
      -- correct refresh period (and other delays).
      CLK_FREQ_G             : real;
      DEV_PARAMS_G           : SDRAMDevParamsType := SDRAM_DEV_PARAMS_DEFAULT_C;
      -- use external IO registers for output
      EXT_OUT_REG_G          : boolean := false;
      -- add a pipeline stage to the bus interface
      -- 0 -> no stage
      -- 1 -> register captures input signals;
      --      combinatial 'ack'
      -- 2 -> added buffer registers for input signals;
      --      registered 'ack'
      INP_REG_G              : natural := 0
   );
   port (
      clk                    : in  std_logic;
      -- bus interface
      --   handshake (req/ack)
      req                    : in  std_logic;
      rdnwr                  : in  std_logic;
      ack                    : out std_logic;
      addr                   : in  std_logic_vector(DEV_PARAMS_G.R_WIDTH + DEV_PARAMS_G.B_WIDTH + DEV_PARAMS_G.C_WIDTH - 1 downto 0);
      wdat                   : in  std_logic_vector(8*DEV_PARAMS_G.DQ_BYTES - 1 downto 0);
      wstrb                  : in  std_logic_vector(  DEV_PARAMS_G.DQ_BYTES - 1 downto 0) := (others => '1');
      -- pipelined read-back qualified by 'vld'
      rdat                   : out std_logic_vector(8*DEV_PARAMS_G.DQ_BYTES - 1 downto 0);
      vld                    : out std_logic;
      -- initialization done
      rdy                    : out std_logic;
      -- SDRAM interface
      sdramDQInp             : in  std_logic_vector(8*DEV_PARAMS_G.DQ_BYTES - 1 downto 0);
      sdramDQOut             : out std_logic_vector(8*DEV_PARAMS_G.DQ_BYTES - 1 downto 0);
      sdramDQOE              : out std_logic;
      sdramAddr              : out std_logic_vector(DEV_PARAMS_G.R_WIDTH  - 1 downto 0);
      sdramBank              : out std_logic_vector(DEV_PARAMS_G.B_WIDTH  - 1 downto 0);
      sdramCSb               : out std_logic;
      sdramRASb              : out std_logic;
      sdramCASb              : out std_logic;
      sdramWEb               : out std_logic;
      sdramCKE               : out std_logic;
      sdramDQM               : out std_logic_vector(DEV_PARAMS_G.DQ_BYTES - 1 downto 0)
   );
end entity SDRAMCtrl;

architecture rtl of SDRAMCtrl is
   type StateType is (INIT, INIT_REFRESH, IDLE, ACTIVATE, PRECHARGE, ACTIVE, AUTOREF);

   -- RASb-CASb-WEb
   subtype CmdType is std_logic_vector(2 downto 0);

   -- reduce amount of typing
   constant P_C                  : SDRAMDevParamsType := DEV_PARAMS_G;
   constant R_WIDTH_C            : natural := P_C.R_WIDTH;
   constant B_WIDTH_C            : natural := P_C.B_WIDTH;
   constant C_WIDTH_C            : natural := P_C.C_WIDTH;
   constant DQ_BYTES_C           : natural := P_C.DQ_BYTES;

   constant CMD_NOP_C            : CmdType := "111";
   constant CMD_ACTIVATE_C       : CmdType := "011";
   constant CMD_WRITE_C          : CmdType := "100";
   constant CMD_READ_C           : CmdType := "101";
   constant CMD_PRECHARGE_C      : CmdType := "010";
   constant CMD_SET_MODE_C       : CmdType := "000";
   constant     MODE_BURST_1_C   : std_logic_vector(2 downto 0) := "000";
   constant     MODE_ASEQ_C      : std_logic_vector(3 downto 3) := "0";
   constant     MODE_CAS_LAT_C   : std_logic_vector(6 downto 4) := std_logic_vector( to_unsigned( P_C.CAS_LAT, 3 ) );
   constant     MODE_TST_NRM_C   : std_logic_vector(8 downto 7) := "00";
   constant     MODE_WBRST_C     : std_logic_vector(9 downto 9) := "0";
   constant     MODE_RSRVD_C     : std_logic_vector(P_C.R_WIDTH - 1 downto 10) := (others => '0');
   constant     MODE_ADDR_C      : std_logic_vector(sdramAddr'range) := 
                                      MODE_RSRVD_C     &
                                      MODE_WBRST_C     &
                                      MODE_TST_NRM_C   &
                                      MODE_CAS_LAT_C   &
                                      MODE_ASEQ_C      &
                                      MODE_BURST_1_C;
   constant     MODE_BANK_C      : std_logic_vector(sdramBank'range) := (others => '0');
   constant CMD_REFRESH_C        : CmdType := "001";

   function clicks(constant t : in real)
   return natural is
   begin
      return natural( ceil( CLK_FREQ_G * t ) );
   end function clicks;

   function nbits(constant x : natural)
   return natural is
      variable rv : natural;
      variable t  : natural;
   begin
      rv := 1;
      t  := 2;
      while ( x >= t ) loop
         t  := 2*t;
         rv := rv + 1;
      end loop;
      return rv;
   end function nbits;

   procedure timerInit(variable t : out signed; constant x : in natural) is
   begin
      t := to_signed( x - 1, t'length );
   end procedure timerInit;

   function timerInit(constant x : natural)
   return signed is
      -- extend by sign bit
      variable v : signed( nbits(x - 1) downto 0 );
   begin
      timerInit( v, x );
      return v;
   end function timerInit;

   function timerValue(constant x : signed)
   return integer is
   begin   
      return to_integer( x + 1 );
   end function timerValue;

   function max(constant a, b: in integer)
   return integer is
   begin
     if ( a > b ) then return a; else return b; end if;
   end function max;

   function row(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(a'left downto a'left - R_WIDTH_C + 1);
   end function row;

   function bnk(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(B_WIDTH_C + C_WIDTH_C - 1 downto C_WIDTH_C );
   end function bnk;

   function col(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(C_WIDTH_C - 1 downto 0);
   end function col;


   constant C_RP_C               : integer := clicks( P_C.T_RP );
   constant C_RFC_C              : integer := clicks( P_C.T_RFC );
   constant C_RAS_C              : integer := clicks( P_C.T_RAS_MIN );
   constant C_RCD_C              : integer := clicks( P_C.T_RCD );
   constant C_SET_MODE_C         : integer := 1;

   constant T_REFRESH_C          : signed := timerInit( clicks( P_C.T_REF/(2.0**real(R_WIDTH_C)) ) - C_RFC_C - C_RP_C );
   -- full period is timerValue( T_REFRESH_C ) + 1 cycles
   constant T_INIT_C             : signed := timerInit( clicks( P_C.T_INIT / real( timerValue( T_REFRESH_C ) + 1 ) ) );

   type SDRAMOutType is record
      dq                         : std_logic_vector(8*DQ_BYTES_C - 1 downto 0);
      oe                         : std_logic;
      addr                       : std_logic_vector(R_WIDTH_C  - 1 downto 0);
      bank                       : std_logic_vector(B_WIDTH_C  - 1 downto 0);
      cmd                        : CmdType;
      cke                        : std_logic;
      dqm                        : std_logic_vector(DQ_BYTES_C - 1 downto 0);
      csb                        : std_logic;
   end record SDRAMOutType;

   constant SDRAM_OUT_INIT_C : SDRAMOutType := (
      dq                         => (others => '0'),
      oe                         => '0',
      addr                       => (others => '0'),
      bank                       => (others => '0'),
      csb                        => '1',
      cmd                        => CMD_NOP_C,
      cke                        => '1',
      dqm                        => (others => '1')
   );

   -- read latency increased by 1 due to our pipeline (output register);
   subtype RdLatType       is std_logic_vector(P_C.CAS_LAT - 1 downto 0);
   -- time write -> precharge; since there is a 1 cycle delay in our pipeline we subtract one
   subtype WrLatType       is std_logic_vector(P_C.WR_LAT  - 2 downto 0);


   constant RDPIPE_EMPTY_C : RdLatType := (others => '0');

   constant WRPIPE_EMPTY_C : WrLatType := (others => '0');

   type RegType is record
      state            : StateType;
      sdram            : SDRAMOutType;
      row              : std_logic_vector(R_WIDTH_C  - 1 downto 0);
      bnk              : std_logic_vector(B_WIDTH_C  - 1 downto 0);
      lstBnk           : std_logic_vector(B_WIDTH_C  - 1 downto 0);
      refTimer         : signed( T_REFRESH_C'range );
      iniTimer         : signed( T_INIT_C'range );
      timer            : signed( nbits(C_RAS_C) downto 0 );
      rdLat            : RdLatType;
      wrLat            : WrLatType;
      vld              : std_logic;
      rdy              : std_logic;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state            => INIT,
      sdram            => SDRAM_OUT_INIT_C,
      row              => (others => '0'),
      bnk              => (others => '0'),
      lstBnk           => (others => '0'),
      refTimer         => T_REFRESH_C,
      iniTimer         => T_INIT_C,
      timer            => (others => '1'),
      rdLat            => (others => '0'),
      wrLat            => (others => '0'),
      vld              => '0',
      rdy              => '0'
   );

   type ReqType is record
      req              : std_logic;
      rdnwr            : std_logic;
      addr             : std_logic_vector(R_WIDTH_C + B_WIDTH_C + C_WIDTH_C - 1 downto 0);
      wdat             : std_logic_vector(8*DQ_BYTES_C - 1 downto 0);
      wstrb            : std_logic_vector(  DQ_BYTES_C - 1 downto 0);
      sameBank         : boolean;
      sameRow          : boolean;
   end record ReqType;

   constant REQ_INIT_C : ReqType := (
      req              => '0',
      rdnwr            => '0',
      addr             => (others => '0'),
      wdat             => (others => '0'),
      wstrb            => (others => '0'),
      sameBank         => false,
      sameRow          => false
   );

   signal usrReq       : ReqType;
   signal locReq       : ReqType;
   signal locAck       : std_logic;

   signal r            : RegType := REG_INIT_C;
   signal rin          : RegType;

   signal sdram        : SDRAMOutType;

begin

   assert P_C.T_RAS_MAX > P_C.T_REF / 2.0**real( R_WIDTH_C ) report "T_RAS_MAX < refresh period unsupported" severity failure;

   G_EXT_OUT_REG : if ( EXT_OUT_REG_G ) generate
      sdram            <= rin.sdram;
      vld              <= rin.vld;
   end generate G_EXT_OUT_REG;

   G_LOC_OUT_REG : if ( not EXT_OUT_REG_G ) generate
      sdram            <= r.sdram;
      vld              <= r.vld;
   end generate G_LOC_OUT_REG;

   G_NO_INP_STAGE : if ( INP_REG_G = 0 ) generate
      locReq       <= usrReq;
      ack          <= locAck;
   end generate G_NO_INP_STAGE;

   G_INP_STAGE    : if ( INP_REG_G > 0 ) generate
      signal rInp    : ReqType := REQ_INIT_C;
      signal bInp    : ReqType := REQ_INIT_C;
      signal rinInp  : ReqType;
      signal binInp  : ReqType;
   begin

      G_INP_STG_1 : if ( INP_REG_G = 1 ) generate

         P_IN_COMB : process ( rInp, r, usrReq, locAck ) is
            variable v : ReqType;
         begin
            v      := rInp;
            ack    <= '0';
            locReq <= rInp;

            if ( (v.req and locAck) = '1' ) then
               v.req := '0';
            end if;

            if ( r.state = ACTIVATE ) then
               -- new bank/row is being activated; the bank/row against which the
               -- address (currently held in rInp) was compared is being opened,
               -- i.e., the row in rInp *is* the 'current' row/bank
               v.sameBank := true;
               v.sameRow  := true;
            end if;

            if ( (usrReq.req and not v.req) = '1' ) then 
               v   := usrReq;
               ack <= '1';
            end if;

            rinInp <= v;
         end process P_IN_COMB;

      end generate G_INP_STG_1;

      G_INP_STG_2 : if ( INP_REG_G > 1 ) generate

         P_IN_COMB : process ( rInp, bInp, r, usrReq, locAck ) is
            variable v : ReqType;
            variable b : ReqType;
         begin
            v      := rInp;
            b      := bInp;

            ack    <= not bInp.req;
            locReq <= rInp;

            if ( r.state = ACTIVATE ) then
               -- new bank/row is being activated; the pre-computed comparison
               -- of 'sameBank/sameRow' is no longer valid; in fact, the about
               -- to be activated bank/row *is* the requesting bank/row
               if ( bInp.req = '0' ) then
                  -- easy case: the shadow register is empty; we can just update
                  -- sameBank/sameRow
                  v.sameBank := true;
                  v.sameRow  := true;
               else
                  b.sameBank := true;
                  b.sameRow  := true;
                  -- if the shadow register is the current requestor we
                  -- also must update the input register
                  v.sameRow  := ( row( rInp.addr ) = row( bInp.addr ) );
                  v.sameBank := ( bnk( rInp.addr ) = bnk( bInp.addr ) );
               end if;
            end if;

            if ( bInp.req = '1' ) then
               locReq <= bInp;
               if ( locAck = '1' ) then
                  b.req  := '0';
               end if;
            else
               if ( rInp.req = '1' ) then
                  -- bInp.req = '0' implies ack = '1'
                  if ( locAck = '1' ) then
                     v.req := '0';
                  else
                     -- cannot consume input; must store in bInp and turn off 'ack'
                     b     := rInp;
                     v.req := '0';
                  end if;
               end if;
               -- input register is empty, 'ack' is '1'
               v := usrReq;
            end if;

            rinInp <= v;
            binInp <= b;
         end process P_IN_COMB;

      end generate G_INP_STG_2;

      P_IN_SEQ : process ( clk ) is
      begin
         if ( rising_edge( clk ) ) then
            rInp <= rinInp;
            bInp <= binInp;
         end if;
      end process P_IN_SEQ;

   end generate G_INP_STAGE;

   usrReq.req   <= req;
   usrReq.rdnwr <= rdnwr;
   usrReq.addr  <= addr;
   usrReq.wdat  <= wdat;
   usrReq.wstrb <= wstrb;

   usrReq.sameBank <= ( bnk(usrReq.addr) = r.bnk );
   usrReq.sameRow  <= ( row(usrReq.addr) = r.row );

   P_COMB : process ( r, locReq ) is
      variable v : RegType;
   begin
      v          := r;

      if ( r.refTimer >= 0 ) then
         v.refTimer := r.refTimer - 1;
      end if;
      if ( r.timer >= 0 ) then
         v.timer    := r.timer - 1;
      end if;

      locAck      <= '0';

      v.sdram.cmd := CMD_NOP_C;
      v.sdram.oe  := '0';
      v.sdram.dqm := (others => '0');
      v.rdLat     := '0' & r.rdLat(r.rdLat'left downto 1);
      v.wrLat     := '0' & r.wrLat(r.wrLat'left downto 1);
      v.vld       := r.rdLat(0);

      case ( r.state ) is

         when INIT =>
            v.sdram.dqm := (others => '1');
            if ( r.iniTimer >= 0 ) then
               -- wait for the initialization period to expire
               if ( r.refTimer < 0 ) then
                  v.refTimer := T_REFRESH_C;
                  v.iniTimer := r.iniTimer - 1;
               end if;
            else
               -- precharge all banks
               v.sdram.csb      := '0';
               v.sdram.addr(10) := '1';
               if ( r.sdram.csb = '1' ) then
                  v.sdram.cmd   := CMD_PRECHARGE_C;
                  timerInit( v.timer, C_RP_C );
               elsif ( r.timer < 0 ) then
                  v.state       := INIT_REFRESH;
                  v.sdram.cmd   := CMD_SET_MODE_C;
                  v.sdram.addr  := MODE_ADDR_C;
                  v.sdram.bank  := MODE_BANK_C;
                  -- use refresh timer to delay the first refresh until MODE required delay
                  timerInit( v.refTimer, C_SET_MODE_C );
                  -- use the iniTimer to count refresh cycles
                  timerInit( v.iniTimer, P_C.N_INIT_REFRESH );
               end if;
            end if;

         when INIT_REFRESH =>
            -- initial refresh cycles
            if ( r.refTimer < 0 ) then
               if ( r.iniTimer < 0 ) then
                  v.state    := IDLE;
                  v.refTimer := T_REFRESH_C;
               else
                  v.iniTimer  := r.iniTimer - 1;
                  v.sdram.cmd := CMD_REFRESH_C;
                  timerInit( v.refTimer, C_RFC_C - 1 );
               end if;
            end if;

         when IDLE =>
            v.rdy := '1'; -- initialization done
            if ( r.refTimer < 0 ) then
               v.sdram.cmd := CMD_REFRESH_C;
               -- 1 cycle is spent in IDLE at least; subtract
               timerInit( v.refTimer, C_RFC_C - 1 ); 
               v.state     := AUTOREF;
            elsif ( locReq.req = '1' ) then
               -- new request; must activate
               v.sdram.cmd  := CMD_ACTIVATE_C;
               v.row        := row( locReq.addr );
               v.sdram.addr := row( locReq.addr );
               v.bnk        := bnk( locReq.addr );
               v.sdram.bank := bnk( locReq.addr );
               v.lstBnk     := bnk( locReq.addr );
               -- 1 cycle spent in ACTIVATE and another one in ACTIVE until read/write CMD is issued
               timerInit( v.timer, C_RCD_C - 2 );
               v.state      := ACTIVATE;
            end if;

         when ACTIVATE =>
            if ( r.bnk     /= r.lstBnk ) then
               if ( r.wrLat = WRPIPE_EMPTY_C ) then
                  -- precharge previous bank
                  v.sdram.addr(10) := '0';
                  v.sdram.cmd      := CMD_PRECHARGE_C;
                  v.sdram.bank     := r.lstBnk;
                  v.lstBnk         := r.bnk;
               end if;
            else
               if ( r.timer < 0 ) then
                  -- set timer to remaining time
                  timerInit( v.timer, C_RAS_C - C_RCD_C );
                  v.state := ACTIVE;
               end if;
            end if;

         when PRECHARGE =>
            if ( r.timer <= 0 ) then
               v.state := IDLE;
            end if;

         when ACTIVE =>
            if ( r.refTimer < 0 ) then
               -- refresh necessary; wait for C_RAS_C to expire
               if ( ( r.timer < 0 ) and ( r.wrLat = WRPIPE_EMPTY_C ) ) then
                  v.state          := PRECHARGE;
                  v.sdram.addr(10) := '0';
                  v.sdram.cmd      := CMD_PRECHARGE_C;
                  -- 1 cycle spent in IDLE until refresh is issued
                  timerInit( v.timer, C_RP_C - 1 );
               end if;
            elsif ( locReq.req = '1' ) then
               if ( locReq.sameBank ) then
                  if ( locReq.sameRow ) then
                     -- *hit* we have the bank available
                     v.sdram.addr  := (others => '0');
                     v.sdram.addr( C_WIDTH_C - 1 downto 0) := col( locReq.addr );
                     v.sdram.dq    := locReq.wdat;
                     v.sdram.bank  := bnk( locReq.addr );
                     if ( locReq.rdnwr = '0' ) then
                         -- WRITE
                         -- note: during this cycle is is OK if VLD is asserted;
                         -- the bus is only turned during the next cycle...
                         if ( r.rdLat = RDPIPE_EMPTY_C ) then
                            v.sdram.dqm             := not locReq.wstrb;
                            v.sdram.oe              := '1';
                            v.wrLat( v.wrLat'left ) := '1';
                            v.sdram.cmd             := CMD_WRITE_C;
                            locAck                  <= '1';
                         end if;
                     else
                         -- READ
                         v.rdLat( v.rdLat'left ) := '1';
                         v.sdram.cmd             := CMD_READ_C;
                         locAck                  <= '1';
                     end if;
                  else
                     -- row switch within the same bank; wait for C_RAS_C to expire, precharge and go through idle
                     if ( ( r.timer < 0 ) and ( r.wrLat = WRPIPE_EMPTY_C ) ) then
                        v.state          := PRECHARGE;
                        v.sdram.addr(10) := '0';
                        v.sdram.cmd      := CMD_PRECHARGE_C;
                        -- 1 cycle spent in IDLE until refresh is issued
                        timerInit( v.timer, C_RP_C - 1 );
                     end if;
                  end if;
               else
                  -- bank switch
                  if ( r.timer < 0 ) then
                     -- C_RAS_C has expired (assume  T_RRD < T_RAS_MIN ); we wait for C_RAS_C
                     -- because we are going to preload this bank immediately after activating
                     -- the new one
                     v.sdram.cmd  := CMD_ACTIVATE_C;
                     v.row        := row( locReq.addr );
                     v.sdram.addr := row( locReq.addr );
                     v.bnk        := bnk( locReq.addr );
                     v.sdram.bank := bnk( locReq.addr );
                     -- 1 cycle spent in ACTIVATE and another one in ACTIVE until read/write CMD is issued
                     timerInit( v.timer, C_RCD_C - 2 );
                     v.state      := ACTIVATE;
                  end if;
               end if;
            end if;

         when AUTOREF =>
            if ( r.refTimer < 0 ) then
               v.state    := IDLE;
               -- restart autorefresh period; note that the constant has already been decremented
               -- by 1 so *dont* use the 'timerInit' function.
               v.refTimer := T_REFRESH_C;
            end if;
      end case;

      rin        <= v;
   end process P_COMB;

   P_SEQ : process ( clk ) is
   begin
      if ( rising_edge( clk ) ) then
         r <= rin;
      end if;
   end process P_SEQ;


   sdramDQOut          <= sdram.dq;
   sdramDQOE           <= sdram.oe;
   sdramAddr           <= sdram.addr;
   sdramBank           <= sdram.bank;
   sdramCSb            <= sdram.csb;
   sdramRASb           <= sdram.cmd(2);
   sdramCASb           <= sdram.cmd(1);
   sdramWEb            <= sdram.cmd(0);
   sdramCKE            <= sdram.cke;
   sdramDQM            <= sdram.dqm;
   rdat                <= sdramDQInp;
   rdy                 <= r.rdy;

end architecture rtl;
