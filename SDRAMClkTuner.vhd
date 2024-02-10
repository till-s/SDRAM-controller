-- Module to help tuning the SDRAM clock phase
-- (with respect to the FPGA internal clock).
-- The optimal phase of the write- as well as the read
-- clock is tuned.

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;

entity SDRAMClkTuner is
   generic (
      ADDR_WIDTH_G           : natural;
      DQ_BYTES_G             : natural := 2
   );
   port (
      clk                    : in  std_logic;
      -- bus interface
      --   handshake (req/ack)
      req                    : out std_logic;
      rdnwr                  : out std_logic;
      ack                    : in  std_logic;
      addr                   : out std_logic_vector(ADDR_WIDTH_G - 1 downto 0);
      wdat                   : out std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      -- pipelined read-back qualified by 'vld'
      rdat                   : in  std_logic_vector(8*DQ_BYTES_G - 1 downto 0);
      vld                    : in  std_logic;
      -- initialization done
      rdy                    : in  std_logic;
      -- diagnostics
      wfail                  : out std_logic
    );
end entity SDRAMClkTuner;

architecture rtl of SDRAMClkTuner is

   constant PRIME_C      : unsigned := to_unsigned( 65521, 8*DQ_BYTES_G );

   subtype  CountType    is signed(3 downto 0);

   type     StateType    is ( INIT, WAI, WLOOP, WPREP, WRITE, CHECK, WNEXT );

   type     RegType      is record
      state              : StateType;
      nxtState           : StateType;
      waiCnt             : CountType;
      wdat               : unsigned(8*DQ_BYTES_G - 1 downto 0);
      wreg               : unsigned(8*DQ_BYTES_G - 1 downto 0);
      rdnwr              : std_logic;
      req                : std_logic;
      addr               : unsigned(ADDR_WIDTH_G - 1 downto 0);
      wfail              : std_logic;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state              => INIT,
      nxtState           => INIT,
      waiCnt             => (others => '1'),
      wdat               => (others => '0'),
      wreg               => PRIME_C,
      rdnwr              => '0',
      req                => '0',
      addr               => (others => '0'),
      wfail              => '0'
   );

   signal r              : RegType := REG_INIT_C;
   signal rin            : RegType := REG_INIT_C;

   procedure doWait(variable v : inout RegType; constant s : in StateType) is
   begin
      v          := v;
      v.nxtState := s;
      v.state    := WAI;
   end procedure doWait;

begin

   P_COMB : process ( r, ack, rdy, rdat, vld ) is
      variable v : RegType;
   begin
      v    := r;

      v.wfail := '0';

      if ( ( r.req and ack ) = '1' ) then
         v.req      := '0';
         v.wdat     := (others => '0');
      end if;

      if ( r.waiCnt >= 0 ) then
         v.waiCnt   := r.waiCnt - 1;
      else
         -- automatically restart
         v.waiCnt(v.waiCnt'left) := '0';
      end if;

      case ( r.state ) is
         when INIT  =>
            if ( rdy = '1' ) then
               v.state    := WNEXT;
            end if;

         when WAI =>
            v.waiCnt := ( v.waiCnt'left => '0', others => '1' );
            v.state  := WLOOP;

         when WLOOP =>
            if ( r.waiCnt < 0 ) then
               v.state := r.nxtState;
            end if;

         when WPREP =>
            -- apply constant address, wdat, control signals
            v.rdnwr    := '0';
            v.wdat     := (others => '0');
            doWait( v, WRITE );

         when WRITE =>
            -- for one cycle apply wdat, control signals
            -- then switch wdat back to all zero/NOP
            v.req      := '1';
            v.wdat     := r.wreg;
            doWait( v, CHECK );

         when CHECK =>
            -- wait with stable address; then read back and compare
            -- (wait count was automatically reset set)
            v.rdnwr    := '1';
            if ( ( r.waiCnt < 0 ) ) then
               -- wait has expired; inhibit auto-reload
               v.waiCnt(v.waiCnt'left) := '1';
               -- wait for 'vld'
               if  ( vld = '1' ) then
                  if ( rdat /= std_logic_vector( r.wreg ) ) then
                     v.wfail := '1';
                  end if;
                  v.state    := WNEXT;
               end if;
            else
               -- keep reading
               v.req      := '1';
            end if;

         when WNEXT =>
            -- wait for ack
            if ( r.req = '0' ) then
               v.rdnwr := '0';
               v.addr  := r.addr + 1;
               v.wdat  := (others => '0');
               if ( r.wreg = 1 ) then
                  -- keep writing non-zero values that
                  -- change when the addresses wrap around
                  v.wreg := PRIME_C;
               else
                  v.wreg := r.wreg - 1;
               end if;
               doWait( v, WRITE );
            end if;

      end case;

      rin  <= v;
   end process P_COMB;

   P_SEQ : process ( clk ) is
   begin
      if ( rising_edge( clk ) ) then
         r <= rin;
      end if;
   end process P_SEQ;

   req     <= r.req;
   rdnwr   <= r.rdnwr;
   wdat    <= std_logic_vector( r.wdat );
   addr    <= std_logic_vector( r.addr );
   wfail   <= r.wfail;
end architecture rtl;
