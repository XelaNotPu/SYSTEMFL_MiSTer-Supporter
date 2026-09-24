-- SPDX-License-Identifier: GPL-3.0-or-later
-- C75 internal RAM: registered old-data read, CE-gated write, no reset clear.
-- Debug bytes mirror writes rather than adding asynchronous memory read ports.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity fl_mcu_ram is
    port(clk,enable,wr: in std_logic;
         address: in unsigned(8 downto 0);
         data: in std_logic_vector(7 downto 0);
         q,debug_80,debug_83: out std_logic_vector(7 downto 0));
end entity;
architecture rtl of fl_mcu_ram is
    type ram_t is array(0 to 511) of std_logic_vector(7 downto 0);
    signal ram: ram_t := (others => (others => '0'));
    signal tap_80,tap_83: std_logic_vector(7 downto 0) := (others => '0');
begin
    debug_80<=tap_80;
    debug_83<=tap_83;
    process(clk) begin
        if rising_edge(clk) and enable='1' then
            if wr='1' then
                ram(to_integer(address))<=data;
                if address=0 then tap_80<=data; end if;
                if address=3 then tap_83<=data; end if;
            end if;
            q<=ram(to_integer(address));
        end if;
    end process;
end architecture;
