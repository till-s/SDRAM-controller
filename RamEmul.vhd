library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;

entity RamEmul is
   generic (
      A_WIDTH_G : natural;
      RDPIPEL_G : natural := 5
   );
   port (
      clk       : in  std_logic;
      req       : in  std_logic;
      rdnwr     : in  std_logic;
      addr      : in  std_logic_vector(A_WIDTH_G - 1 downto 0);
      ack       : out std_logic;
      vld       : out std_logic;
      wdat      : in  std_logic_vector(15 downto 0);
      rdat      : out std_logic_vector(15 downto 0)
   );
end entity RamEmul;

architecture rtl of RamEmul is

   type RamArray is array ( natural range <> ) of std_logic_vector(15 downto 0);

   signal mem  : RamArray(0 to 2**A_WIDTH_G - 1);
   signal rpip : RamArray(0 to RDPIPEL_G - 1);
   signal vpip : std_logic_vector(0 to RDPIPEL_G - 1) := (others => '0');

   signal ackd : signed(4 downto 0) := (others => '1');
   signal cnt  : natural := 0;

begin

   process ( clk ) is
   begin
      if ( rising_edge( clk ) ) then

         vpip(0) <= '0';
         rpip(0) <= mem( to_integer( unsigned( addr ) ) );

         if ( ackd >= 0 ) then
            ackd <= ackd - 1;
         else
            if ( req = '1' ) then
               vpip(0) <= rdnwr;
               if ( rdnwr = '0' ) then
                  mem( to_integer( unsigned( addr ) ) ) <= wdat;
               end if;
            end if;
         end if;

         if ( cnt = 0 ) then
            ackd <= to_signed( 5, ackd'length );
            cnt  <= 13;
         else
            cnt  <= cnt - 1;
         end if;

         for i in 1 to rpip'high loop
            rpip(i) <= rpip(i-1);
            vpip(i) <= vpip(i-1);
         end loop;
      end if;
   end process;

   ack  <= ackd(ackd'left);
   rdat <= rpip(rpip'high);
   vld  <= vpip(vpip'high);

end architecture rtl;
