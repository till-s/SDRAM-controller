library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;
use     ieee.math_real.all;

entity SDRAMCtrl is
   generic (
      -- clock frequency
      CLK_FREQ_G             : real    := 166.0E6;
      -- refresh period
      T_REF_G                : real    := 64.0E-3;
      -- autorefresh cycle time
      T_RFC_G                : real    := 60.0E-9;
      -- precharge time
      T_RP_G                 : real    := 15.0E-9;
      -- active to precharge
      T_RAS_MIN_G            : real    := 42.0E-9;
      -- controller assumes that refresh period/row-count is smaller than T_RAS_MAX_G
      T_RAS_MAX_G            : real    := 100.0E-6;
      -- active to read/write
      T_RCD_G                : real    := 15.0E-9;
      CAS_LAT_G              : natural := 3; -- cycles
      -- write-recovery
      WR_LAT_G               : natural := 2; -- cycles
      DQ_BYTES_G             : natural := 2;
      -- row-address width
      A_WIDTH_G              : natural := 13;
      -- bank-address width
      B_WIDTH_G              : natural := 2;
      -- column-address width
      C_WIDTH_G              : natural := 8
   );
   port (
      clk                    : in  std_logic;
      -- bus interface
      --   handshake (req/ack)
      req                    : in  std_logic;
      rdnwr                  : in  std_logic;
      ack                    : out std_logic;
      addr                   : in  std_logic_vector(A_WIDTH_G + B_WIDTH_G + C_WIDTH_G - 1 downto 0);
      wdat                   : in  std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      wstrb                  : in  std_logic_vector(  DQ_BYTES_G - 1 downto 0) := (others => '1');
      -- pipelined read-back qualified by 'vld'
      rdat                   : out std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      vld                    : out std_logic;
      -- SDRAM interface
      sdramDQInp             : in  std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      sdramDQOut             : out std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      sdramDQOE              : out std_logic;
      sdramAddr              : out std_logic_vector(A_WIDTH_G  - 1 downto 0);
      sdramBank              : out std_logic_vector(B_WIDTH_G  - 1 downto 0);
      sdramCSb               : out std_logic;
      sdramRASb              : out std_logic;
      sdramCASb              : out std_logic;
      sdramWEb               : out std_logic;
      sdramCKE               : out std_logic;
      sdramDQM               : out std_logic_vector(DQ_BYTES_G - 1 downto 0)
   );
end entity SDRAMCtrl;

architecture rtl of SDRAMCtrl is
   type StateType is (INIT, IDLE, ACTIVATE, PRECHARGE, ACTIVE, AUTOREF);

   -- RASb-CASb-WEb
   subtype CmdType is std_logic_vector(2 downto 0);

   constant CMD_NOP_C            : CmdType := "111";
   constant CMD_ACTIVATE_C       : CmdType := "011";
   constant CMD_WRITE_C          : CmdType := "100";
   constant CMD_READ_C           : CmdType := "101";
   constant CMD_PRECHARGE_C      : CmdType := "010";
   constant CMD_SET_MODE_C       : CmdType := "000";
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
      timerInit( v, x - 1 );
      return v;
   end function timerInit;

   function max(constant a, b: in integer)
   return integer is
   begin
     if ( a > b ) then return a; else return b; end if;
   end function max;

   function row(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(a'left downto a'left - A_WIDTH_G + 1);
   end function row;

   function bnk(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(B_WIDTH_G + C_WIDTH_G - 1 downto C_WIDTH_G );
   end function bnk;

   function col(constant a : std_logic_vector)
   return std_logic_vector is
   begin
      return a(C_WIDTH_G - 1 downto 0);
   end function col;


   constant C_RP_C               : integer := clicks( T_RP_G );
   constant C_RFC_C              : integer := clicks( T_RFC_G );
   constant C_RAS_C              : integer := clicks( T_RAS_MIN_G );
   constant C_RCD_C              : integer := clicks( T_RCD_G );

   constant T_REFRESH_C          : signed := timerInit( clicks( T_REF_G/(2.0**real(A_WIDTH_G)) ) - C_RFC_C - C_RP_C );

   type SDRAMOutType is record
      dq                         : std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      oe                         : std_logic;
      addr                       : std_logic_vector(A_WIDTH_G  - 1 downto 0);
      bank                       : std_logic_vector(B_WIDTH_G  - 1 downto 0);
      cmd                        : CmdType;
      cke                        : std_logic;
      dqm                        : std_logic_vector(DQ_BYTES_G - 1 downto 0);
      csb                        : std_logic;
   end record SDRAMOutType;

   constant SDRAM_OUT_INIT_C : SDRAMOutType := (
      dq                         => (others => '0'),
      oe                         => '0',
      addr                       => (others => '0'),
      bank                       => (others => '0'),
      csb                        => '0',
      cmd                        => CMD_NOP_C,
      cke                        => '1',
      dqm                        => (others => '0')
   );

   -- read latency increased by 1 due to our pipeline (output register);
   subtype RdLatType       is std_logic_vector(CAS_LAT_G    downto 0);
   -- time write -> precharge; since there is a 1 cycle delay in our pipeline we subtract one
   subtype WrLatType       is std_logic_vector(WR_LAT_G - 2 downto 0);


   constant RDPIPE_EMPTY_C : RdLatType := (others => '0');

   constant WRPIPE_EMPTY_C : WrLatType := (others => '0');

   type RegType is record
      state            : StateType;
      sdram            : SDRAMOutType;
      row              : std_logic_vector(A_WIDTH_G  - 1 downto 0);
      bnk              : std_logic_vector(B_WIDTH_G  - 1 downto 0);
      lstBnk           : std_logic_vector(B_WIDTH_G  - 1 downto 0);
      refTimer         : signed( T_REFRESH_C'range );
      timer            : signed( nbits(C_RAS_C) downto 0 );
      rdLat            : RdLatType;
      wrLat            : WrLatType;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state            => INIT,
      sdram            => SDRAM_OUT_INIT_C,
      row              => (others => '0'),
      bnk              => (others => '0'),
      lstBnk           => (others => '0'),
      refTimer         => (others => '1'),
      timer            => (others => '1'),
      rdLat            => (others => '0'),
      wrLat            => (others => '0')
   );

   signal r            : RegType := REG_INIT_C;
   signal rin          : RegType;

   signal sdram        : SDRAMOutType;
   signal dqInpLoc     : std_logic_vector(sdramDQInp'range);

begin

   assert T_RAS_MAX_G > T_REF_G / 2.0**real( A_WIDTH_G ) report "T_RAS_MAX < refresh period unsupported" severity failure;

   sdram               <= r.sdram;
   dqInpLoc            <= sdramDQInp;

   P_COMB : process ( r, req, rdnwr, addr, wdat, wstrb, dqInpLoc ) is
      variable v : RegType;
   begin
      v          := r;

      if ( r.refTimer >= 0 ) then
         v.refTimer := r.refTimer - 1;
      end if;
      if ( r.timer >= 0 ) then
         v.timer    := r.timer - 1;
      end if;

      ack         <= '0';

      v.sdram.cmd := CMD_NOP_C;
      v.sdram.oe  := '0';
      v.sdram.dqm := (others => '0');
      v.rdLat     := '0' & r.rdLat(r.rdLat'left downto 1);
      v.wrLat     := '0' & r.wrLat(r.wrLat'left downto 1);

      case ( r.state ) is

         when INIT =>
            v.state := IDLE;

         when IDLE =>
            if ( r.refTimer < 0 ) then
               v.sdram.cmd := CMD_REFRESH_C;
               -- 1 cycle is spent in IDLE at least; subtract
               timerInit( v.refTimer, C_RFC_C - 1 ); 
               v.state     := AUTOREF;
            elsif ( req = '1' ) then
               -- new request; must activate
               v.sdram.cmd  := CMD_ACTIVATE_C;
               v.row        := row( addr );
               v.sdram.addr := row( addr );
               v.bnk        := bnk( addr );
               v.sdram.bank := bnk( addr );
               v.lstBnk     := bnk( addr );
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
                  -- set timer to remaining time; 1 cycle spent in ACTIVE until precharge
                  timerInit( v.timer, C_RAS_C - C_RCD_C - 1 );
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
            elsif ( req = '1' ) then
               if ( bnk( addr ) = r.bnk ) then
                  if ( row( addr ) = r.row ) then
                     -- *hit* we have the bank available
                     v.sdram.addr  := (others => '0');
                     v.sdram.addr( C_WIDTH_G - 1 downto 0) := col( addr );
                     v.sdram.dq    := wdat;
                     v.sdram.bank  := bnk( addr );
                     if ( rdnwr = '0' ) then
                         -- WRITE
                         if ( r.rdLat = RDPIPE_EMPTY_C ) then
                            v.sdram.dqm             := not wstrb;
                            v.sdram.oe              := '1';
                            v.wrLat( v.wrLat'left ) := '1';
                            v.sdram.cmd             := CMD_WRITE_C;
                            ack                     <= '1';
                         end if;
                     else
                         -- READ
                         v.rdLat( v.rdLat'left ) := '1';
                         v.sdram.cmd             := CMD_READ_C;
                         ack                     <= '1';
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
                     -- C_RAS_C has expired (assume  T_RRD < T_RAS_MIN )
                     v.sdram.cmd  := CMD_ACTIVATE_C;
                     v.row        := row( addr );
                     v.sdram.addr := row( addr );
                     v.bnk        := bnk( addr );
                     v.sdram.bank := bnk( addr );
                     -- 1 cycle spent in ACTIVATE and another one in ACTIVE until read/write CMD is issued
                     timerInit( v.timer, C_RCD_C - 2 );
                     v.state      := ACTIVATE;
                  end if;
               end if;
            end if;

         when AUTOREF =>
            if ( r.refTimer < 0 ) then
               v.state    := IDLE;
               -- restart autorefresh period
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
   vld                 <= r.rdLat(0);
end architecture rtl;
