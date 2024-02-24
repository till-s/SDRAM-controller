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
      wfail                  : out std_logic;
      rfail                  : out std_logic;
      -- address wrapp-around (toggles, i.e, can be connected to a LED)
      awrap                  : out std_logic
    );
end entity SDRAMClkTuner;

architecture rtl of SDRAMClkTuner is

   constant PRIME_C      : unsigned := to_unsigned( 65521, 8*DQ_BYTES_G );
   constant RBRST_C      : natural  := 4;

   subtype  CountType    is signed(3 downto 0);

   constant WAI_INI_C    : CountType := (CountType'left => '0', others => '1');

   type     StateType    is ( INIT, WAI, WLOOP, WPREP, WRITE, CHECK, RETRYRD, WNEXT, ISWDON, RTEST );

   type     RegType      is record
      state              : StateType;
      nxtState           : StateType;
      waiCnt             : CountType;
      rdCnt              : signed(5 downto 0);
      wdat               : unsigned(8*DQ_BYTES_G - 1 downto 0);
      wreg               : unsigned(8*DQ_BYTES_G - 1 downto 0);
      rdnwr              : std_logic;
      req                : std_logic;
      addr               : unsigned(ADDR_WIDTH_G - 1 downto 0);
      vldSeen            : std_logic;
      wfail              : std_logic;
      wfailed            : std_logic; -- latched version
      rfail              : std_logic;
      awrap              : std_logic;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state              => INIT,
      nxtState           => INIT,
      waiCnt             => WAI_INI_C,
      rdCnt              => (others => '1'),
      wdat               => (others => '0'),
      wreg               => PRIME_C,
      rdnwr              => '0',
      req                => '0',
      addr               => (others => '0'),
      vldSeen            => '0',
      wfail              => '0',
      wfailed            => '0',
      rfail              => '0',
      awrap              => '0'
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
      v.rfail := '0';

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
               v.state    := WPREP;
            end if;

         when WAI =>
            v.waiCnt := WAI_INI_C;
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
            v.rdCnt    := to_signed( RBRST_C, v.rdCnt'length );
            v.vldSeen  := '0';
            doWait( v, CHECK );

         when CHECK =>
            -- read burst with stable address
            v.rdnwr    := '1';
            if ( r.req = '1' ) then
               if ( ack = '1' ) then
                  v.rdCnt := r.rdCnt - 1;
               else
                  -- burst non-contiguous
                  v.state := RETRYRD;
               end if;
            end if;
            if ( v.rdCnt >= 0 ) then
               -- next read
               v.req := '1';
            end if;
            v.vldSeen := vld;
            if ( (r.vldSeen = '1' ) and (r.rdCnt < 0 ) ) then
               if ( vld = '1' ) then
                  if ( rdat /= std_logic_vector( r.wreg ) ) then
                     v.wfail   := '1';
                     v.wfailed := '1';
                  end if;
               else
                  v.state := WNEXT;
               end if;
            end if;

         when RETRYRD =>
            -- get here when r.req = '1', ack = '0'
            v.vldSeen := '0';
            v.rdCnt   := to_signed( RBRST_C, v.rdCnt'length );
            if ( ack = '1' ) then
               -- wait for read pipeline to drain
               doWait(v, CHECK);
            end if;
 
         when WNEXT =>
            v.addr  := r.addr + 1;
            v.wdat  := (others => '0');
            if ( r.wreg = 1 ) then
               -- keep writing non-zero values that
               -- change when the addresses wrap around
               v.wreg := PRIME_C;
            else
               v.wreg := r.wreg - 1;
            end if;
            v.state := ISWDON;

         when ISWDON =>
            if ( ( r.addr = 0 ) ) then
               v.state := RTEST;
               v.wreg  := PRIME_C;
               v.rdnwr := '1';
               v.req   := '1';
               v.awrap := not r.awrap;
            else
               v.state := WPREP;
            end if;

         when RTEST =>
            if ( (r.req and ack) = '1' ) then
               v.addr  := r.addr  + 1;
               v.rdCnt := r.rdCnt + 1;
               if ( v.addr /= 0 ) then
                  v.req    := '1';
               end if;
            end if;
            if ( vld = '1' ) then
               v.rdCnt := v.rdCnt - 1;
               if ( (rdat /= std_logic_vector( r.wreg )) ) then
                  v.rfail := '1';
               end if;
               if ( r.wreg = 1 ) then
                  v.wreg := PRIME_C;
               else
                  v.wreg := r.wreg - 1;
               end if;
            end if;
            -- one full sweep of addresses; wait for pipe
            -- to drain and start over
            if ( (r.req = '0') and (r.rdCnt < 0 ) ) then
               -- r.addr = 0 at this point
               v.state := ISWDON;
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
   rfail   <= r.rfail;
   awrap   <= r.awrap;
end architecture rtl;
