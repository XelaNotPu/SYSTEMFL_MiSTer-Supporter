-- SPDX-License-Identifier: GPL-3.0-or-later
-- Single-clock runtime BIOS storage with independent write and read ports.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity fl_bios_ram is
    port(clk,wr: in std_logic;
         waddr,raddr: in std_logic_vector(13 downto 0);
         data: in std_logic_vector(7 downto 0);
         q: out std_logic_vector(7 downto 0));
end entity;
architecture rtl of fl_bios_ram is
    type ram_t is array(0 to 16383) of std_logic_vector(7 downto 0);
    signal ram: ram_t;
begin
    process(clk) begin
        if rising_edge(clk) then
            if wr='1' then ram(to_integer(unsigned(waddr)))<=data; end if;
            q<=ram(to_integer(unsigned(raddr)));
        end if;
    end process;
end architecture;
