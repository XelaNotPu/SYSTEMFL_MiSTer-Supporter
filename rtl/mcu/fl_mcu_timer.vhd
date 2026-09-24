-- SPDX-License-Identifier: GPL-3.0-or-later
-- M37702 timer mode for the C75's previously absent A0/A1/A4 channels.
-- Clock selectors 00/01/10/11 divide the MCU clock by 2/16/64/512.
-- Underflow reloads the programmed value; zero therefore has a one-tick period.
-- Event-counter, one-shot, and PWM modes require separate implementations.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fl_mcu_timer is
    port (
        clk,ce,reset,start : in std_logic;
        mode : in std_logic_vector(7 downto 0);
        reload : in unsigned(15 downto 0);
        count : out unsigned(15 downto 0);
        tick : out std_logic
    );
end entity;

architecture rtl of fl_mcu_timer is
    signal divider : unsigned(8 downto 0) := (others=>'0');
    signal divider_limit : unsigned(8 downto 0);
    signal counter : unsigned(15 downto 0) := (others=>'0');
    signal armed : std_logic := '0';
begin
    with mode(7 downto 6) select divider_limit <=
        to_unsigned(1,9) when "00", to_unsigned(15,9) when "01",
        to_unsigned(63,9) when "10", to_unsigned(511,9) when others;
    count <= counter;
    process(clk) begin
        if rising_edge(clk) then
            if reset='1' then
                divider<=(others=>'0'); counter<=(others=>'0'); armed<='0'; tick<='0';
            elsif ce='1' then
                tick<='0';
                if start='0' or mode(1 downto 0)/="00" then
                    armed<='0'; divider<=(others=>'0'); counter<=reload;
                elsif armed='0' then
                    armed<='1'; divider<=(others=>'0'); counter<=reload;
                elsif divider=divider_limit then
                    divider<=(others=>'0');
                    if counter=0 then counter<=reload; tick<='1';
                    else counter<=counter-1; end if;
                else divider<=divider+1;
                end if;
            end if;
        end if;
    end process;
end architecture;
