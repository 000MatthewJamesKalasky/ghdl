--  Routine to dump (for debugging purpose) a netlist.
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

with Simple_IO; use Simple_IO;
with Name_Table;
with Files_Map;

with Netlists.Utils; use Netlists.Utils;
with Netlists.Iterators; use Netlists.Iterators;
with Netlists.Gates; use Netlists.Gates;
with Netlists.Locations;

package body Netlists.Dump is
   procedure Put_Indent (Indent : Natural) is
   begin
      Put (String'(1 .. Indent * 2 => ' '));
   end Put_Indent;

   --  Like Put, but without the leading space (if any).
   procedure Put_Trim (S : String) is
   begin
      if S'First <= S'Last and then S (S'First) = ' ' then
         Put (S (S'First + 1 .. S'Last));
      else
         Put (S);
      end if;
   end Put_Trim;

   procedure Put_Uns32 (V : Uns32) is
   begin
      Put_Trim (Uns32'Image (V));
   end Put_Uns32;

   procedure Put_Width (W : Width) is
   begin
      Put_Trim (Width'Image (W));
   end Put_Width;

   procedure Dump_Name (N : Sname)
   is
      use Name_Table;
      Prefix : Sname;
   begin
      --  Do not crash on No_Name.
      if N = No_Sname then
         Put ("*nil*");
         return;
      end if;

      Prefix := Get_Sname_Prefix (N);

      case Get_Sname_Kind (N) is
         when Sname_User =>
            if Prefix = No_Sname then
               Put ("\");
            else
               Dump_Name (Prefix);
               Put (".");
            end if;
            Put (Image (Get_Sname_Suffix (N)));
         when Sname_Artificial =>
            if Prefix = No_Sname then
               Put ("$");
            else
               Dump_Name (Prefix);
               Put (".");
            end if;
            Put (Image (Get_Sname_Suffix (N)));
         when Sname_Version =>
            if Prefix /= No_Sname then
               Dump_Name (Prefix);
            end if;
            Put ("%");
            Put_Uns32 (Get_Sname_Version (N));
      end case;
   end Dump_Name;

   procedure Dump_Input_Name (I : Input; With_Id : Boolean := False)
   is
      Inst : constant Instance := Get_Input_Parent (I);
      Idx : constant Port_Idx := Get_Port_Idx (I);
      M : constant Module := Get_Module (Inst);
   begin
      Dump_Name (Get_Instance_Name (Inst));
      Put ('.');
      if Is_Self_Instance (Inst) then
         Dump_Name (Get_Output_Desc (M, Idx).Name);
      else
         if Idx < Get_Nbr_Inputs (M) then
            Dump_Name (Get_Input_Desc (M, Idx).Name);
         else
            Put_Trim (Port_Nbr'Image (Idx));
         end if;
      end if;
      if With_Id then
         Put ("{p");
         Put_Trim (Input'Image (I));
         Put ('}');
      end if;
   end Dump_Input_Name;

   procedure Dump_Net_Name (N : Net; With_Id : Boolean := False)
   is
      Inst : constant Instance := Get_Net_Parent (N);
      Idx : constant Port_Idx := Get_Port_Idx (N);
   begin
      Dump_Name (Get_Instance_Name (Inst));
      Put ('.');
      if Is_Self_Instance (Inst) then
         Dump_Name (Get_Input_Desc (Get_Module (Inst), Idx).Name);
      else
         Dump_Name (Get_Output_Desc (Get_Module (Inst), Idx).Name);
      end if;
      if With_Id then
         Put ("{n");
         Put_Trim (Net'Image (N));
         Put ('}');
      end if;
   end Dump_Net_Name;

   procedure Dump_Parameter (Inst : Instance; Idx : Param_Idx)
   is
      Desc : constant Param_Desc := Get_Param_Desc (Inst, Idx);
   begin
      if Desc.Name /= No_Sname then
         --  Const_Bit/Log gates have anonymous parameters.
         Dump_Name (Desc.Name);
         Put ('=');
      end if;

      case Desc.Typ is
         when Param_Invalid =>
            Put ("invalid");
         when Param_Uns32 =>
            Put_Uns32 (Get_Param_Uns32 (Inst, Idx));
      end case;
   end Dump_Parameter;

   procedure Dump_Instance (Inst : Instance; Indent : Natural := 0)
   is
      Loc : constant Location_Type := Locations.Get_Location (Inst);
   begin
      if Loc /= No_Location then
         declare
            File : Name_Id;
            Line : Positive;
            Col : Natural;
         begin
            Put_Indent (Indent);
            Put ("# ");
            Files_Map.Location_To_Position (Loc, File, Line, Col);
            Put (Name_Table.Image (File));
            Put (':');
            Put_Uns32 (Uns32 (Line));
            Put (':');
            Put_Uns32 (Uns32 (Col));
            New_Line;
         end;
      end if;

      Put_Indent (Indent);
      Put ("instance ");
      Dump_Name (Get_Instance_Name (Inst));
      Put (" {i");
      Put_Trim (Instance'Image (Inst));
      Put ('}');
      Put (": ");
      Dump_Name (Get_Module_Name (Get_Module (Inst)));
      New_Line;

      if Get_Nbr_Params (Inst) > 0 then
         Put_Indent (Indent + 1);
         Put ("parameters");
         for P in Params (Inst) loop
            pragma Warnings (Off, P);
            Put (' ');
            Dump_Parameter (Inst, Get_Param_Idx (P));
         end loop;
         New_Line;
      end if;

      if Get_Nbr_Inputs (Inst) > 0 then
         for I of Inputs (Inst) loop
            Put_Indent (Indent + 1);
            Put ("input ");
            Dump_Input_Name (I, True);
            Put (" <- ");
            declare
               N : constant Net := Get_Driver (I);
            begin
               if N /= No_Net then
                  Dump_Net_Name (N, True);
                  Put (':');
                  Put_Width (Get_Width (N));
               end if;
            end;
            New_Line;
         end loop;
      end if;

      if Get_Nbr_Outputs (Inst) > 0 then
         Put_Indent (Indent + 1);
         Put ("outputs");
         for O of Outputs (Inst) loop
            Put (' ');
            Dump_Net_Name (O, True);
            Put (':');
            Put_Width (Get_Width (O));
         end loop;
         New_Line;
      end if;
   end Dump_Instance;

   procedure Disp_Width (W : Width) is
   begin
      if W /= 1 then
         Put ('[');
         if W = 0 then
            Put ('?');
         else
            Put_Width (W - 1);
            Put (":0");
         end if;
         Put (']');
      end if;
   end Disp_Width;

   procedure Dump_Module_Header (M : Module; Indent : Natural := 0) is
   begin
      --  Module id and name.
      Put_Indent (Indent);
      Put ("module {m");
      Put_Trim (Module'Image (M));
      Put ("} ");
      Dump_Name (Get_Module_Name (M));
      New_Line;

      --  Parameters.
      for P of Params_Desc (M) loop
         Put_Indent (Indent + 1);
         Put ("parameter");
         Put (' ');
         Dump_Name (P.Name);
         Put (": ");
         case P.Typ is
            when Param_Invalid =>
               Put ("invalid");
            when Param_Uns32 =>
               Put ("uns32");
         end case;
         New_Line;
      end loop;

      --  Ports.
      for P of Ports_Desc (M) loop
         Put_Indent (Indent + 1);
         case P.Dir is
            when Port_In =>
               Put ("input");
            when Port_Out =>
               Put ("output");
            when Port_Inout =>
               Put ("inout");
         end case;
         Put (' ');
         Dump_Name (P.Name);
         Disp_Width (P.W);
         Put (';');
         New_Line;
      end loop;
   end Dump_Module_Header;

   procedure Dump_Module (M : Module; Indent : Natural := 0) is
   begin
      Dump_Module_Header (M, Indent);

      for S of Sub_Modules (M) loop
         Dump_Module (S, Indent + 1);
      end loop;

      declare
         Self : constant Instance := Get_Self_Instance (M);
      begin
         if Self /= No_Instance then
            Dump_Instance (Self, Indent + 1);
         end if;
      end;

      for Inst of Instances (M) loop
         Dump_Instance (Inst, Indent + 1);
      end loop;

      for N of Nets (M) loop
         Put_Indent (Indent + 1);
         Put ("connect ");
         Dump_Net_Name (N, True);

         declare
            First : Boolean;
         begin
            First := True;
            for S of Sinks (N) loop
               if First then
                  Put (" -> ");
                  First := False;
               else
                  Put (", ");
               end if;
               Dump_Input_Name (S, True);
            end loop;
         end;
         New_Line;
      end loop;
   end Dump_Module;

   procedure Disp_Net_Name (N : Net) is
   begin
      if N = No_Net then
         Put ("?");
      else
         declare
            Inst : constant Instance := Get_Net_Parent (N);
            Idx : constant Port_Idx := Get_Port_Idx (N);
         begin
            if Is_Self_Instance (Inst) then
               Dump_Name (Get_Input_Desc (Get_Module (Inst), Idx).Name);
            else
               Dump_Name (Get_Instance_Name (Inst));
               Put ('.');
               Dump_Name (Get_Output_Desc (Get_Module (Inst), Idx).Name);
            end if;
         end;
      end if;
   end Disp_Net_Name;

   procedure Dump_Net_Name_And_Width (N : Net) is
   begin
      if N = No_Net then
         Put ("?");
      else
         Disp_Net_Name (N);
         Disp_Width (Get_Width (N));

         Put ("{n");
         Put_Trim (Net'Image (N));
         Put ('}');
      end if;
   end Dump_Net_Name_And_Width;

   function Can_Inline (Inst : Instance) return Boolean is
   begin
      case Get_Id (Inst) is
         when Id_Signal
           | Id_Output =>
            --  Cut loops.
            return False;
         when others =>
            null;
      end case;
      return not Is_Self_Instance (Inst)
        and then Get_Nbr_Outputs (Inst) = 1
        and then Has_One_Connection (Get_Output (Inst, 0));
   end Can_Inline;

   procedure Disp_Driver (Drv : Net)
   is
      Drv_Inst : Instance;
   begin
      if Drv = No_Net then
         Put ('?');
      else
         Drv_Inst := Get_Net_Parent (Drv);
         if Flag_Disp_Inline and then Can_Inline (Drv_Inst) then
            Disp_Instance (Drv_Inst, False);
         else
            Disp_Net_Name (Drv);
         end if;
      end if;
   end Disp_Driver;

   --  Debug routine: disp net driver
   procedure Debug_Net (N : Net) is
   begin
      if N = No_Net then
         Put ('?');
      else
         Disp_Instance (Get_Net_Parent (N), False);
      end if;
      New_Line;
   end Debug_Net;

   pragma Unreferenced (Debug_Net);

   Xdigits : constant array (Uns32 range 0 ..15) of Character :=
     "0123456789abcdef";

   procedure Disp_Instance (Inst : Instance; With_Name : Boolean)
   is
      M : constant Module := Get_Module (Inst);
   begin
      if True then
         --  Pretty-print for some gates
         case Get_Id (M) is
            when Id_Const_UB32 =>
               declare
                  W : constant Width := Get_Width (Get_Output (Inst, 0));
                  V : Uns32;
                  I : Natural;
               begin
                  Put_Width (W);
                  Put ("'uh");
                  V := Get_Param_Uns32 (Inst, 0);
                  I := (Natural (W) + 3) / 4;
                  while I > 0 loop
                     I := I - 1;
                     Put (Xdigits (Shift_Right (V, I * 4) and 15));
                  end loop;
               end;
               return;

            when Id_Extract =>
               declare
                  W : constant Width := Get_Width (Get_Output (Inst, 0));
                  Off : constant Uns32 := Get_Param_Uns32 (Inst, 0);
               begin
                  Disp_Driver (Get_Input_Net (Inst, 0));
                  Put ('[');
                  if W > 1 then
                     Put_Uns32 (Off + W - 1);
                     Put (':');
                  end if;
                  Put_Uns32 (Off);
                  Put (']');
                  return;
               end;

            when others =>
               null;
         end case;
      end if;

      Dump_Name (Get_Module_Name (M));

      if True then
         Put ("{i");
         Put_Trim (Instance'Image (Inst));
         Put ('}');
      end if;

      if Get_Nbr_Params (Inst) > 0 then
         declare
            First : Boolean;
         begin
            First := True;
            Put (" #(");
            for P in Params (Inst) loop
               pragma Warnings (Off, P);
               if not First then
                  Put (", ");
               end if;
               First := False;
               Dump_Parameter (Inst, Get_Param_Idx (P));
            end loop;
            Put (")");
         end;
      end if;

      if With_Name then
         Put (' ');
         Dump_Name (Get_Instance_Name (Inst));
      end if;

      if Get_Nbr_Inputs (Inst) > 0 then
         declare
            First : Boolean;
            Drv : Net;
         begin
            First := True;
            Put (" (");
            for I of Inputs (Inst) loop
               if not First then
                     Put (", ");
               end if;
               First := False;

               Drv := Get_Driver (I);

               Put ("{n");
               Put_Trim (Net'Image (Drv));
               Put ('}');

               Disp_Driver (Drv);
            end loop;
            Put (')');
         end;
      end if;
   end Disp_Instance;

   procedure Disp_Instance_Assign (Inst : Instance; Indent : Natural := 0) is
   begin
      Put_Indent (Indent);
      case Get_Nbr_Outputs (Inst) is
         when 0 =>
            null;
         when 1 =>
            Dump_Net_Name_And_Width (Get_Output (Inst, 0));
            Put (" := ");
         when others =>
            declare
               First : Boolean;
            begin
               First := True;
               Put ('(');
               for O of Outputs (Inst) loop
                  if not First then
                     Put (", ");
                  end if;
                  First := False;
                  Dump_Net_Name_And_Width (O);
               end loop;
               Put (") := ");
            end;
      end case;

      Disp_Instance (Inst, False);
      New_Line;
   end Disp_Instance_Assign;

   procedure Disp_Module (M : Module; Indent : Natural := 0) is
   begin
      --  Name and ports.
      Dump_Module_Header (M, Indent);

      --  Submodules.
      for S of Sub_Modules (M) loop
         if Get_Id (S) >= Id_User_None then
            Disp_Module (S, Indent + 1);
         end if;
      end loop;

      for Inst of Instances (M) loop
         if not (Flag_Disp_Inline and then Can_Inline (Inst)) then
            Disp_Instance_Assign (Inst, Indent + 1);
         end if;
      end loop;

      --  Assignments to outputs.
      declare
         Self : constant Instance := Get_Self_Instance (M);
      begin
         if Self /= No_Instance then
            for I of Inputs (Self) loop
               Put_Indent (Indent + 1);
               Dump_Name (Get_Output_Desc (M, Get_Port_Idx (I)).Name);
               Put (" := ");
               if False then
                  Disp_Driver (Get_Driver (I));
               else
                  Dump_Net_Name_And_Width (Get_Driver (I));
               end if;
               New_Line;
            end loop;
         end if;
      end;
   end Disp_Module;
end Netlists.Dump;
