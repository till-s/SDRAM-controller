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

   procedure tick is
   begin
      wait until rising_edge( clk );
   end procedure tick;

begin

   process is
   begin
      if not run then wait; end if;
      wait for 3 ns; clk <= not clk;
   end process;

   process is
   begin
      tick;
      req <= '1';
      rnw <= '0';
      for i in 254 to 257 loop
         adr  <= to_unsigned(i, adr'length);
         wdat <= std_logic_vector(to_unsigned(i-254, wdat'length));
         tick;
         while ack = '0' loop
            tick;
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
 
      run <= false;      
      wait;
   end process;

   U_DUT : entity work.SDRAMCtrl
      port map (
         clk        => clk,
         req        => req,
         addr       => std_logic_vector(adr),
         wdat       => wdat,
         rdnwr      => rnw,
         ack        => ack,
         vld        => vld,
         sdramDQInp => x"0000"
      );

end architecture sim;
