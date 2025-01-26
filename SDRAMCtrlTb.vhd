-- Copyright Till Straumann, 2024. Licensed under the EUPL-1.2 or later.
-- You may obtain a copy of the license at
--   https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
-- This notice must not be removed.

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;
use     ieee.math_real.all;

entity SDRAMCtrlTb is
end entity SDRAMCtrlTb;

architecture sim of SDRAMCtrlTb is
   signal clk  : std_logic := '0';
   signal adr  : unsigned(22 downto 0) := (others => '0');
   signal req  : std_logic := '0';
   signal ack  : std_logic;
   signal wdat : std_logic_vector(15 downto 0) := (others => '0');
   signal run  : boolean   := true;
   signal rnw  : std_logic := '0';
   signal vld  : std_logic;
   signal rdy  : std_logic;

   signal ramDQOut: std_logic_vector(15 downto 0);
   signal ramDQOE : std_logic;
   signal ramAddr : std_logic_vector(12 downto 0);
   signal ramBank : std_logic_vector( 1 downto 0);
   signal ramCSb  : std_logic;
   signal ramRASb : std_logic;
   signal ramCASb : std_logic;
   signal ramWEb  : std_logic;
   signal sdramDQM: std_logic_vector( 1 downto 0);

   procedure tick is
   begin
      wait until rising_edge( clk );
   end procedure tick;

begin

   process is
   begin
      if not run then wait; end if;
      wait for 1000.0 ns / 166.0 / 2.0; clk <= not clk;
   end process;

   process is
      variable timo : integer;
   begin
      tick;
      while ( rdy = '0' ) loop
         tick;
      end loop;
      req <= '1';
      rnw <= '0';
      for i in 254 to 257 loop
         adr  <= to_unsigned(i, adr'length);
         wdat <= std_logic_vector(to_unsigned(i-254, wdat'length));
         tick;
         timo := 0;
         while ack = '0' loop
            tick;
            timo := timo + 1;
            assert timo < 100 report "no ACK" severity failure;
         end loop;
      end loop;
      adr <= to_unsigned( 256 + 1024, adr'length );
      wdat <= x"ffff";
      tick;
      while ack = '0' loop
         tick;
      end loop;
      req <= '0';
      tick;
      req <= '1';
      rnw <= '1';
      tick;
      while ack = '0' loop
         tick;
      end loop;
      req <= '0';
      while vld = '0' loop
         tick;
      end loop;
      tick;
      -- switching rows...
      adr  <= "0" & x"abc" & "00" & x"00";
      req  <= '1';
      wdat <= x"dead";
      while ack = '0' loop
         tick;
      end loop;

      adr  <= "0" & x"abd" & "00" & x"00";
      req  <= '1';
      wdat <= x"beef";
      while ack = '0' loop
         tick;
      end loop;
 
      adr  <= "0" & x"abe" & "00" & x"00";
      req  <= '1';
      wdat <= x"affe";
      while ack = '0' loop
         tick;
      end loop;
      req <= '0';
      tick;
  
      run <= false;      
      wait;
   end process;

   U_DUT : entity work.SDRAMCtrl
      generic map (
         CLK_FREQ_G => 100.0E6,
         INP_REG_G  => 2
      )
      port map (
         clk        => clk,
         req        => req,
         addr       => std_logic_vector(adr),
         wdat       => wdat,
         rdnwr      => rnw,
         ack        => ack,
         vld        => vld,
         rdy        => rdy,
         sdramDQInp => x"0000",
         sdramDQOut => ramDQOut,
         sdramDQOE  => ramDQOE,
         sdramAddr  => ramAddr,
         sdramBank  => ramBank,
         sdramCSb   => ramCSb,
         sdramRASb  => ramRASb,
         sdramCASb  => ramCASb,
         sdramWEb   => ramWEb,
         sdramDQM   => sdramDQM
      );

   P_REP : process ( clk ) is
      function toStr(constant x : std_logic_vector)
      return string is
      begin
         return integer'image( to_integer( unsigned( x ) ) );
      end function toStr;

      function toStr(constant x : std_logic)
      return string is
      begin
         return std_logic'image( x );
      end function toStr;

   begin
      if ( rising_edge( clk ) ) then
         report toStr(ramDQOE) & toStr(ramRASb) & toStr(ramCASb) & toStr(ramWEb) & " " & toStr(ramBank) & " " & toStr(ramAddr) & " " & toStr(ramDQOut) ;
      end if;
   end process P_REP;

end architecture sim;
