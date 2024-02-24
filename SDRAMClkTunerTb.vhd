-- Copyright Till Straumann, 2024. Licensed under the EUPL-1.2 or later.
-- You may obtain a copy of the license at
--   https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
-- This notice must not be removed.

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;

entity SDRAMClkTunerTb is
end entity SDRAMClkTunerTb;

architecture sim of SDRAMClkTunerTb is

   constant AWIDTH_C             : natural   := 8;

   signal clk                    : std_logic := '0';
   signal req                    : std_logic;
   signal rdnwr                  : std_logic;
   signal ack                    : std_logic;
   signal addr                   : std_logic_vector(AWIDTH_C - 1 downto 0);
   signal wdat                   : std_logic_vector(16       - 1 downto 0);
   signal rdat                   : std_logic_vector(16       - 1 downto 0);
   signal vld                    : std_logic;
   signal rdy                    : std_logic := '0';
   signal wfail                  : std_logic;

   signal run                    : boolean := true;

   signal count                  : integer := 5000;

begin

   process is
   begin
      if ( not run ) then wait; end if;
      wait for 5 us;
      clk <= not clk;
   end process;

   process ( clk ) is
   begin
      if ( rising_edge( clk ) ) then
         assert wfail = '0' report "WFAIL" severity failure;
         rdy   <= '1';
         count <= count - 1;
         if ( count < 0 ) then
            run <= false;
            report "PASSED";
         end if;
      end if;
   end process;

   U_RAM : entity work.RamEmul
      generic map (
         A_WIDTH_G => AWIDTH_C,
         RDPIPEL_G => 5
      )
      port map (
         clk       => clk,
         req       => req,
         rdnwr     => rdnwr,
         addr      => addr,
         ack       => ack,
         vld       => vld,
         wdat      => wdat,
         rdat      => rdat
      );

   U_DUT : entity work.SDRAMClkTuner
      generic map (
         ADDR_WIDTH_G           => AWIDTH_C
      )
      port map (
         clk                    => clk,
         req                    => req,
         rdnwr                  => rdnwr,
         ack                    => ack,
         addr                   => addr,
         wdat                   => wdat,
         rdat                   => rdat,
         vld                    => vld,
         rdy                    => rdy,
         wfail                  => wfail
       );

end architecture sim;
