library ieee;
use     ieee.math_real.all;

package SDRAMCtrlPkg is

   -- SDRAM device parameters.

   -- all 'T_xxx' parameters are in seconds
   type SDRAMDevParamsType is record
      -- Max clock frequency supported by the device (in Hz)
      CLK_FREQ_MAX           : real;
      -- Refresh period
      T_REF                  : real;
      -- Autorefresh cycle time
      T_RFC                  : real;
      -- Precharge time
      T_RP                   : real;
      -- Active to precharge
      T_RAS_MIN              : real;
      -- Controller assumes that refresh period/row-count is smaller than T_RAS_MAX  
      T_RAS_MAX              : real;
      -- Active to read/write
      T_RCD                  : real;
      -- Initial pause
      T_INIT                 : real;
      -- Number of initial auto-refresh cycles required
      N_INIT_REFRESH         : natural;
      -- CAS latency (in cycles)
      CAS_LAT                : natural;
      -- Write-recovery (in cycles)
      WR_LAT                 : natural;
      -- Data-bus width (in bytes)
      DQ_BYTES               : natural;
      -- Row-address width (in bits)
      R_WIDTH                : natural;
      -- Bank-address width (in bits)
      B_WIDTH                : natural;
      -- Column-address width (in bits)
      C_WIDTH                : natural;
   end record SDRAMDevParamsType;

   constant SDRAM_DEV_PARAMS_DEFAULT_C : SDRAMDevParamsType := (
      CLK_FREQ_MAX            => 166.0E6,
      T_REF                   => 64.0E-3,
      T_RFC                   => 60.0E-9,
      T_RP                    => 15.0E-9,
      T_RAS_MIN               => 42.0E-9,
      T_RAS_MAX               => 100.0E-6,
      T_RCD                   => 15.0E-9,
      T_INIT                  => 200.0E-6,
      N_INIT_REFRESH          => 8,
      CAS_LAT                 => 3,
      WR_LAT                  => 2,
      DQ_BYTES                => 2,
      R_WIDTH                 => 13,
      B_WIDTH                 => 2,
      C_WIDTH                 => 8
   );

end package SDRAMCtrlPkg;
