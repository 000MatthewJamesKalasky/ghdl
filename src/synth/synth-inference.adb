--  Inference in synthesis.
--  Copyright (C) 2017 Tristan Gingold
--
--  This file is part of GHDL.
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 51 Franklin Street - Fifth Floor, Boston,
--  MA 02110-1301, USA.

with Dyn_Interning;

with Netlists.Utils; use Netlists.Utils;
with Netlists.Gates; use Netlists.Gates;
with Netlists.Gates_Ports; use Netlists.Gates_Ports;
with Netlists.Locations; use Netlists.Locations;

with Synth.Flags;

package body Synth.Inference is
   --  DFF inference.
   --  As an initial implementation, the following 'styles' must be
   --  supported:
   --  Note: rising_edge is any clock_edge; '<=' can be ':='.
   --
   --  1)
   --  if rising_edge(clk) then
   --    r <= x;
   --  end if;
   --
   --  2)
   --  if rst = '0' then
   --    r <= x;
   --  elsif rising_edge (clk) then
   --    r <= y;
   --  end if;
   --
   --  3)
   --  wait until rising_edge(clk);
   --   r <= x;
   --  Which is equivalent to 1) when the wait statement is the only and first
   --  statement, as it can be converted to an if statement.
   --
   --  Netlist derived from 1)
   --      +------+
   --      |      |
   --      |   /| |
   --      |  |0+-+
   --  Q --+--+ |
   --         |1+--- D
   --          \|
   --         CLK
   --  This is a memorizing element as there is a loop, the value is changed
   --  to D on a rising edge of the clock.
   --
   --  Netlist derived from 2)
   --      +------------+
   --      |         /| |
   --      |   /|   |0+-+
   --      |  |0+---+ |
   --  Q --+--+ |   |1+----- D
   --         |1+-+  \|
   --          \| | CLK
   --         RST +--------- '0'
   --  This is a memorizing element as there is a loop.  It is an asynchronous
   --  reset as Q is forced to '0' when RST is asserted.

   function Has_Clock (N : Net) return Boolean
   is
      Inst : constant Instance := Get_Net_Parent (N);
   begin
      case Get_Id (Inst) is
         when Id_Edge =>
            return True;
         when Id_And =>
            --  Assume the condition is canonicalized, ie of the form:
            --  CLK and EXPR.
            --  FIXME: do it!
            return Has_Clock (Get_Input_Net (Inst, 0));
         when others =>
            return False;
      end case;
   end Has_Clock;

   --  Find the longest chain of mux starting from VAL with a final input
   --  of PREV_VAL.  Such a chain means this is a memorising element.
   --  RES is the last mux in the chain, DIST the number of mux in the chain.
   procedure Find_Longest_Loop
     (Val : Net; Prev_Val : Net; Res : out Instance; Dist : out Integer)
   is
      Inst : constant Instance := Get_Parent (Val);
   begin
      if Get_Id (Inst) = Id_Mux2 then
         declare
            Res0, Res1 : Instance;
            Dist0, Dist1 : Integer;
         begin
            if Has_Clock (Get_Driver (Get_Mux2_Sel (Inst))) then
               Res := Inst;
               Dist := 1;
            else
               Find_Longest_Loop
                 (Get_Driver (Get_Mux2_I0 (Inst)), Prev_Val, Res0, Dist0);
               Find_Longest_Loop
                 (Get_Driver (Get_Mux2_I1 (Inst)), Prev_Val, Res1, Dist1);
               --  Input1 has an higher priority than input0 in case
               --  the selector is a clock.
               --  FIXME: improve algorithm.
               if Dist1 > Dist0 then
                  Dist := Dist1 + 1;
                  if Dist1 > 0 then
                     Res := Res1;
                  else
                     Res := Inst;
                  end if;
               elsif Dist0 >= 0 then
                  Dist := Dist0 + 1;
                  if Dist0 > 0 then
                     Res := Res0;
                  else
                     Res := Inst;
                  end if;
               else
                  pragma Assert (Dist1 < 0 and Dist0 < 0);
                  Res := No_Instance;
                  Dist := -1;
               end if;
            end if;
         end;
      elsif Val = Prev_Val then
         Res := No_Instance;
         Dist := 0;
      else
         Res := No_Instance;
         Dist := -1;
      end if;
   end Find_Longest_Loop;

   --  Walk the And-net N, and extract clock (posedge/negedge) if found.
   --  ENABLE is N without the clock.
   procedure Extract_Clock (N : Net; Clk : out Net; Enable : out Net)
   is
      Inst : constant Instance := Get_Net_Parent (N);
   begin
      Clk := No_Net;
      Enable := No_Net;

      case Get_Id (Inst) is
         when Id_Edge =>
            --  Get rid of the edge gate, just return the signal.
            Clk := Get_Input_Net (Inst, 0);
         when Id_And =>
            --  Assume the condition is canonicalized, ie of the form:
            --  CLK and EXPR
            --  EXPR and CLK
            declare
               I0 : constant Net := Get_Input_Net (Inst, 0);
               Inst0 : constant Instance := Get_Net_Parent (I0);
            begin
               if Get_Id (Inst0) = Id_Edge then
                  --  INST is clearly not synthesizable (boolean operation on
                  --  an edge).  Will be removed at the end by
                  --  remove_unused_instances.  Do not remove it now as its
                  --  output may be used by other nets.
                  Clk := Get_Input_Net (Inst0, 0);
                  Enable := Get_Input_Net (Inst, 1);
                  return;
               end if;
            end;
            declare
               I1 : constant Net := Get_Input_Net (Inst, 1);
               Inst1 : constant Instance := Get_Net_Parent (I1);
            begin
               if Get_Id (Inst1) = Id_Edge then
                  --  INST is clearly not synthesizable (boolean operation on
                  --  an edge).  Will be removed at the end by
                  --  remove_unused_instances.  Do not remove it now as its
                  --  output may be used by other nets.
                  Clk := Get_Input_Net (Inst1, 0);
                  Enable := Get_Input_Net (Inst, 0);
                  return;
               end if;
            end;
         when others =>
            null;
      end case;
   end Extract_Clock;

   procedure Check_FF_Else (Els : Net; Prev_Val : Net; Off : Uns32)
   is
      Inst : Instance;
   begin
      if Els = Prev_Val then
         if Off /= 0 then
            raise Internal_Error;
         end if;
         return;
      end if;
      Inst := Get_Parent (Els);
      if Get_Id (Inst) /= Id_Extract then
         raise Internal_Error;
      end if;
      if Get_Param_Uns32 (Inst, 0) /= Off then
         raise Internal_Error;
      end if;
      if Get_Input_Net (Inst, 0) /= Prev_Val then
         raise Internal_Error;
      end if;
   end Check_FF_Else;

   --  LAST_MUX is the mux whose input 0 is the loop.
   procedure Infere_FF (Ctxt : Context_Acc;
                        Wid : Wire_Id;
                        Prev_Val : Net;
                        Off : Uns32;
                        Last_Mux : Instance;
                        Clk : Net;
                        Enable : Net;
                        Stmt : Source.Syn_Src)
   is
      Sel : constant Input := Get_Mux2_Sel (Last_Mux);
      I0 : constant Input := Get_Mux2_I0 (Last_Mux);
      I1 : constant Input := Get_Mux2_I1 (Last_Mux);
      O : constant Net := Get_Output (Last_Mux, 0);
      Data : Net;
      Res : Net;
      Sig : Instance;
      Init : Net;
      Rst : Net;
      Rst_Val : Net;
   begin
      --  Create and return the DFF.

      --  1. Remove the mux that creates the loop (will be replaced by the
      --     dff).
      Disconnect (Sel);
      --  There must be no 'else' part for clock expression.
      Check_FF_Else (Get_Driver (I0), Prev_Val, Off);
      --  Don't try to free driver of I0 as this is Prev_Val.
      Disconnect (I0);
      Data := Get_Driver (I1);
      --  Don't try to free driver of I1 as it is reconnected.
      Disconnect (I1);

      --  If the signal declaration has an initial value, get it.
      Sig := Get_Parent (Prev_Val);
      if Get_Id (Get_Module (Sig)) = Id_Isignal then
         Init := Get_Input_Net (Sig, 1);
         Init := Build2_Extract (Ctxt, Init, Off, Get_Width (O));
      else
         Init := No_Net;
      end if;

      --  Look for asynchronous set/reset.  They are muxes after the loop
      --  mux.  In theory, there can be many set/reset with a defined order.
      Rst_Val := No_Net;
      Rst := No_Net;
      declare
         Mux : Instance;
         Sel : Net;
         Last_Out : Net;
         Mux_Rst : Net;
         Mux_Rst_Val : Net;
      begin
         Last_Out := O;

         while Is_Connected (Last_Out) loop
            if not Has_One_Connection (Last_Out) then
               --  TODO.
               raise Internal_Error;
            end if;

            --  The parent must be a mux (it's a chain of muxes).
            Mux := Get_Parent (Get_First_Sink (Last_Out));
            pragma Assert (Get_Id (Mux) = Id_Mux2);

            --  Extract the reset condition and the reset value.
            Sel := Get_Driver (Get_Mux2_Sel (Mux));
            if Get_Driver (Get_Mux2_I0 (Mux)) = Last_Out then
               Mux_Rst_Val := Get_Driver (Get_Mux2_I1 (Mux));
               Mux_Rst := Sel;
            elsif Get_Driver (Get_Mux2_I1 (Mux)) = Last_Out then
               Mux_Rst_Val := Get_Driver (Get_Mux2_I0 (Mux));
               Mux_Rst := Build_Monadic (Ctxt, Id_Not, Sel);
            else
               --  Cannot happen.
               raise Internal_Error;
            end if;

            Last_Out := Get_Output (Mux, 0);

            if Rst = No_Net then
               --  Remove the last mux.  Dedicated inputs on the FF are used.
               Disconnect (Get_Mux2_I0 (Mux));
               Disconnect (Get_Mux2_I1 (Mux));
               Disconnect (Get_Mux2_Sel (Mux));

               Redirect_Inputs (Last_Out, Mux_Rst_Val);
               Free_Instance (Mux);

               Rst := Mux_Rst;
               Rst_Val := Mux_Rst_Val;
               Last_Out := Mux_Rst_Val;
            else
               Rst := Build_Dyadic (Ctxt, Id_Or, Mux_Rst, Rst);
               Rst_Val := Last_Out;
            end if;
         end loop;
      end;

      --  If there is a condition with the clock, that's an enable which
      --  keep the previous value if the condition is false.  Add the mux
      --  for it.
      if Enable /= No_Net then
         Data := Build_Mux2 (Ctxt, Enable, Prev_Val, Data);
         Copy_Location (Data, Enable);
      end if;

      --  Create the FF.
      if Rst = No_Net then
         pragma Assert (Rst_Val = No_Net);
         if Init /= No_Net then
            Res := Build_Idff (Ctxt, Clk, D => Data, Init => Init);
         else
            Res := Build_Dff (Ctxt, Clk, D => Data);
         end if;
      else
         if Init /= No_Net then
            Res := Build_Iadff (Ctxt, Clk, D => Data,
                                Rst => Rst, Rst_Val => Rst_Val,
                                Init => Init);
         else
            Res := Build_Adff (Ctxt, Clk, D => Data,
                               Rst => Rst, Rst_Val => Rst_Val);
         end if;
      end if;
      Copy_Location (Res, Last_Mux);

      --  The output of the mux may be read later in the process,
      --  like this:
      --    if clk'event and clk = '1' then
      --       d := i + 1;
      --    end if;
      --    d1 := d + 1;
      --  So connections to the mux output are redirected to dff
      --  output.
      Redirect_Inputs (O, Res);

      Free_Instance (Last_Mux);

      Add_Conc_Assign (Wid, Res, Off, Stmt);
   end Infere_FF;

   function Id_Instance (Param : Instance) return Instance is
   begin
      return Param;
   end Id_Instance;

   package Inst_Interning is new Dyn_Interning
     (Params_Type => Instance,
      Object_Type => Instance,
      Hash => Netlists.Hash,
      Build => Id_Instance,
      Equal => "=");

   --  Detect false combinational loop.  They can easily appear when variables
   --  are only used in one branch:
   --    process (all)
   --      variable a : std_logic;
   --    begin
   --      r <= '1';
   --      if sel = '1' then
   --        a := '1';
   --        r <= '0';
   --      end if;
   --    end process;
   --  There is a combinational path from 'a' to 'a' as
   --    a := (sel = '1') ? '1' : a;
   --  But this is a false loop because the value of 'a' is never used.  In
   --  that case, 'a' is assigned to 'x' and all the unused logic will be
   --  removed during clean-up.
   --
   --  Detection is very simple: the closure of readers of 'a' must be only
   --  muxes (which were inserted by controls).
   function Is_False_Loop (Prev_Val : Net) return Boolean
   is
      use Inst_Interning;
      T : Inst_Interning.Instance;

      function Add_From_Net (N : Net) return Boolean
      is
         Inst : Netlists.Instance;
         Inp : Input;
      begin
         Inp := Get_First_Sink (N);
         while Inp /= No_Input loop
            Inst := Get_Input_Parent (Inp);
            if Get_Id (Inst) not in Mux_Module_Id then
               return False;
            end if;

            --  Add to T (if not already).
            Get (T, Inst, Inst);

            Inp := Get_Next_Sink (Inp);
         end loop;

         return True;
      end Add_From_Net;

      function Walk_Nets (N : Net) return Boolean
      is
         Inst : Netlists.Instance;
      begin
         --  Put gates that read the value.
         if not Add_From_Net (N) then
            return False;
         end if;

         --  Follow the outputs.
         for I in First_Index .. Index_Type'Last loop
            exit when I > Inst_Interning.Last_Index (T);
            Inst := Get_By_Index (T, I);
            if not Add_From_Net (Get_Output (Inst, 0)) then
               return False;
            end if;
         end loop;

         --  No external readers.
         return True;
      end Walk_Nets;

      Res : Boolean;
   begin
      Inst_Interning.Init (T);

      Res := Walk_Nets (Prev_Val);

      Inst_Interning.Free (T);

      return Res;
   end Is_False_Loop;

   procedure Infere_Latch (Ctxt : Context_Acc; Val : Net; Prev_Val : Net)
   is
      X : Net;
   begin
      --  In case of false loop, do not close the loop but assign X.
      if Is_False_Loop (Prev_Val) then
         X := Build_Const_X (Ctxt, Get_Width (Val));
         Connect (Get_Input (Get_Net_Parent (Prev_Val), 0), X);
         return;
      end if;

      --  Latch or combinational loop.
      raise Internal_Error;
   end Infere_Latch;

   procedure Infere (Ctxt : Context_Acc;
                     Wid : Wire_Id;
                     Val : Net;
                     Off : Uns32;
                     Prev_Val : Net;
                     Stmt : Source.Syn_Src)
   is
      pragma Assert (Val /= No_Net);
      pragma Assert (Prev_Val /= No_Net);
      Last_Mux : Instance;
      Len : Integer;
      Sel : Input;
      Clk : Net;
      Enable : Net;
   begin
      if not Flags.Flag_Debug_Noinference then
         if Get_First_Sink (Prev_Val) = No_Input then
            --  PREV_VAL is never read, so there cannot be any loop.
            --  This is an important optimization for control signals.
            Len := -1;
         else
            Find_Longest_Loop (Val, Prev_Val, Last_Mux, Len);
         end if;
      else
         Len := -1;
      end if;
      if Len <= 0 then
         --  No logical loop or self assignment.
         Add_Conc_Assign (Wid, Val, Off, Stmt);
      else
         --  So there is a logical loop.
         Sel := Get_Mux2_Sel (Last_Mux);
         Extract_Clock (Get_Driver (Sel), Clk, Enable);
         if Clk = No_Net then
            --  No clock -> latch or combinational loop
            Infere_Latch (Ctxt, Val, Prev_Val);
         else
            --  Clock -> FF
            Infere_FF (Ctxt, Wid, Prev_Val, Off, Last_Mux, Clk, Enable, Stmt);
         end if;
      end if;
   end Infere;
end Synth.Inference;
