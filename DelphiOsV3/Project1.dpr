program Project1;

{$APPTYPE CONSOLE}

uses
  System,
  Windows,
  Messages,
  SysUtils,
  Classes,
  Dialogs,
  Math,
  ShellApi;

const
  EOC_MIN: LongWord = $0FFFFFF8;
  FREE_CLUSTER = $00000000;  // Boþ cluster deðeri
  EOC = $0FFFFFFF;           // Sonlandýrýcý cluster deðeri (FAT32 için)
  CLSA_PER_SECTOR         = 128;


type
  TBootSector = packed record
    JumpCode: array[0..2] of Byte;
    OEMName: array[0..7] of AnsiChar;
    BytesPerSector: Word;
    SectorsPerCluster: Byte;
    ReservedSectors: Word;
    NumberOfFATs: Byte;
    RootEntryCount: Word;
    TotalSectors16: Word;
    Media: Byte;
    FATSize16: Word;
    SectorsPerTrack: Word;
    NumberOfHeads: Word;
    HiddenSectors: LongWord;
    TotalSectors32: LongWord;
    FATSize32: LongWord;
    ExtFlags: Word;
    FSVer: Word;
    RootCluster: LongWord;
    FSInfo: Word;
    BkBootSec: Word;
    Reserved: array[0..11] of Byte;
    DriveNumber: Byte;
    Reserved1: Byte;
    BootSignature: Byte;
    VolumeID: LongWord;
    VolumeLabel: array[0..10] of AnsiChar; // Düzenlendi
    FileSystemType: array[0..7] of AnsiChar;
    BootCode: array[0..419] of Byte;
    BootSectorSignature: Word; // $AA55 olmalý
  end;


  type
  PDirectoryEntry=^TDirectoryEntry;
  TDirectoryEntry = packed record
    Name: array[0..10] of Char; // 8+3 = 11 karakterlik dosya adý ve uzantý
    Attr: Byte;                // Dosya öznitelikleri (örneðin, dizin, dosya vb.)
    Reserved: Byte;
    CreateTimeTenth: Byte;
    CreateTime: Word;
    CreateDate: Word;
    LastAccessDate: Word;
    FirstClusterHigh: Word;   // Cluster numarasýnýn yüksek kýsmý (FAT32'de)
    WriteTime: Word;
    WriteDate: Word;
    FirstClusterLow: Word;    // Cluster numarasýnýn düþük kýsmý
    FileSize: LongWord;       // Dosya boyutu
  end;

var
   BytesPerSector: Word=512;
   SectorsPerCluster: Byte;
   ReservedSectors: Word;
   NumberOfFATs: Byte;
   RootEntryCount: Word;
   TotalSectors32: LongWord;
   FATSize32: LongWord;
   RootCluster: LongWord;
   ImgFile: TFileStream;



procedure FileNameToFat32(FileName: PChar; var FName: array of Char);
var
  i, j, NameLen, ExtLen: Integer;
  DotPos: Integer;
begin
  DotPos := -1;
  i := 0;
  j := 0;
  while FileName[i] <> #0 do
  begin
    if FileName[i] = '.' then
    begin
      DotPos := i;
      Break;
    end;
    Inc(i);
  end;

  if DotPos = -1 then
     DotPos := StrLen(FileName);

  NameLen := Min(DotPos, 8);
  for i := 0 to NameLen - 1 do
  begin
    FName[j] := UpCase(FileName[i]);
    Inc(j);
  end;

  while j < 8 do
  begin
    FName[j] := ' ';
    Inc(j);
  end;

  ExtLen := Min(StrLen(FileName) - DotPos - 1, 3);
  for i := DotPos + 1 to DotPos + ExtLen do
  begin
    FName[j] := UpCase(FileName[i]);
    Inc(j);
  end;

  while j < 11 do
  begin
    FName[j] := ' ';
    Inc(j);
  end;

  FName[j] := #0;
end;

procedure Fat32ToFileName(DiskName: PChar; var FileName: array of Char);
var
  i, j: Integer;
begin
  j := 0;

  for i := 0 to 7 do
  begin
    if DiskName[i] <> ' ' then
    begin
      FileName[j] := DiskName[i];
      Inc(j);
    end;
  end;

  if (DiskName[8] <> ' ') or (DiskName[9] <> ' ') or (DiskName[10] <> ' ') then
  begin
    FileName[j] := '.';
    Inc(j);
    for i := 8 to 10 do
    begin
      if DiskName[i] <> ' ' then
      begin
        FileName[j] := DiskName[i];
        Inc(j);
      end;
    end;
  end;

  FileName[j] := #0;
end;

function ReadSector(LBA: LongWord; Data: Pointer; Size: Integer = 512): Boolean;
begin
  ImgFile.Seek(LBA * BytesPerSector, soBeginning);
  Result := (ImgFile.Read(Data^, Size) = Size);
end;

function WriteSector(LBA: LongWord; Data: Pointer; Size: Integer = 512): Boolean;
begin
   ImgFile.Seek(LBA * BytesPerSector, soBeginning);
   Result := (ImgFile.Write(Data^, Size) = Size);
end;

function ClusterToLBA(Cluster: LongWord; SectorOffset: LongWord = 0): LongWord;
var
  FirstDataSector: LongWord;
begin
  FirstDataSector := ReservedSectors + (NumberOfFATs * FATSize32);
  Result := ((Cluster - 2) * SectorsPerCluster) + FirstDataSector + SectorOffset;
end;

function GetNextCluster(CurrentCluster: LongWord): LongWord;
var
  FatOffset: LongWord;
  FatSector: LongWord;
  EntryOffset: LongWord;
  FatBuffer: array[0..511] of Byte;
begin
  FatOffset := CurrentCluster * 4;
  FatSector := ReservedSectors + (FatOffset div BytesPerSector);
  EntryOffset := FatOffset mod BytesPerSector;

  if not ReadSector(FatSector, @FatBuffer) then
  begin
    WriteLn('FAT sektör okuma baþarýsýz oldu.');
    Result := $FFFFFFFF;
    Exit;
  end;

  Result := PLongWord(@FatBuffer[EntryOffset])^ and $0FFFFFFF;
end;

function SetNextCluster(CurrentCluster, NextCluster: LongWord): Boolean;
var
  FatOffset: LongWord;
  FatSector: LongWord;
  EntryOffset: LongWord;
  FatBuffer: array[0..511] of Byte;
begin
  FatOffset := CurrentCluster * 4;
  FatSector := ReservedSectors + (FatOffset div BytesPerSector);
  EntryOffset := FatOffset mod BytesPerSector;

  if not ReadSector(FatSector, @FatBuffer) then
  begin
    WriteLn('FAT sektör okuma baþarýsýz oldu.');
    Result := False;
    Exit;
  end;

  PLongWord(@FatBuffer[EntryOffset])^ := NextCluster and $0FFFFFFF;

  if not WriteSector(FatSector, @FatBuffer) then
  begin
    WriteLn('FAT sektör yazma baþarýsýz oldu.');
    Result := False;
    Exit;
  end;

  Result := True;
end;


function AllocateNewCluster(var NewCluster: LongWord): Boolean;
var
  Cluster: LongWord;
begin
  Result := False;
  for Cluster := RootCluster to $0FFFFFEF do
  begin
    if GetNextCluster(Cluster) = FREE_CLUSTER then
    begin
      if SetNextCluster(Cluster, $0FFFFFFF) then
      begin
        NewCluster := Cluster;
        Result := True;
        Exit;
      end
      else
      begin
        Result := False;
        Exit;
      end;
    end;
  end;
end;

function FindFileEntry(Cluster: LongWord; filename: PChar; var FoundEntry: TDirectoryEntry;Count:Integer=0): Boolean;
var
  CurrentCluster: LongWord;
  Data: array[0..511] of Byte;
  DirectoryEntry: TDirectoryEntry;
  i,J, EntryOffset: Integer;
  ConvertedName: array[0..11] of Char;
begin

  FileNameToFat32(filename, ConvertedName);

  while Cluster < $0FFFFFF8 do
  begin
   for J := 0 to (SectorsPerCluster - 1) do
    begin
      CurrentCluster := ClusterToLBA(Cluster, J);
      ReadSector(CurrentCluster, @Data);
      for i := 0 to 15 do
      begin
         EntryOffset := i * SizeOf(TDirectoryEntry);
         Move(Data[EntryOffset], DirectoryEntry, SizeOf(TDirectoryEntry));
         if DirectoryEntry.Name[0] = #$00 then
            Exit;
         if DirectoryEntry.Name[0] = #$E5 then
            Continue;

         if CompareMem(PChar(@DirectoryEntry.Name[0]),PChar(@ConvertedName[0]),11) then
         begin
           if Count > 0 then
           begin
             FoundEntry.FileSize:=Count;
             DirectoryEntry.FileSize:=Count;
             Move( DirectoryEntry,Data[EntryOffset], SizeOf(TDirectoryEntry));
             WriteSector(CurrentCluster,@Data);
           end;
            FoundEntry := DirectoryEntry;

           Result := True;
           Exit;
         end;
      end;
    end;
    Cluster := GetNextCluster(Cluster);
  end;
end;

function CreateFileContent(Cluster: LongWord; FileName: PChar;Attr: Byte): Boolean;
const
  Attrib_Read_Only = $01;  // Salt okunur
  Attrib_Hidden = $02;     // Gizli
  Attrib_System = $04;     // Sistem dosyasý
var
  DirectoryEntry: TDirectoryEntry;
  Data: array[0..511] of Byte;
  NewCluster, CurrentCluster: LongWord;
  EntryOffset, j: Integer;
  ConvertedName: array[0..11] of Char;
begin
  Result := False;

  while Cluster < $0FFFFFF8 do
  begin
    for j := 0 to (SectorsPerCluster - 1) do
    begin
      CurrentCluster := ClusterToLBA(Cluster, j);
      ReadSector(CurrentCluster, @Data);

      for EntryOffset := 0 to (512 div SizeOf(TDirectoryEntry)) - 1 do
      begin
        if Data[EntryOffset * SizeOf(TDirectoryEntry)] = $00 then
        begin
          if AllocateNewCluster(NewCluster) then
          begin
           // WriteLn(ClusterToLBA(NewCluster));
            FileNameToFat32(FileName, ConvertedName);
            FillChar(DirectoryEntry, SizeOf(DirectoryEntry), 0);
            Move(ConvertedName[0], DirectoryEntry.Name[0], 11);
            DirectoryEntry.Attr :=Attr;// Attrib_Read_Only or Attrib_Hidden or Attrib_System;
            DirectoryEntry.FirstClusterLow := NewCluster and $FFFF;
            DirectoryEntry.FirstClusterHigh := NewCluster shr 16;
            DirectoryEntry.FileSize := 0;
            Move(DirectoryEntry, Data[EntryOffset * SizeOf(TDirectoryEntry)], SizeOf(TDirectoryEntry));
            WriteSector(CurrentCluster, @Data);
            Result := True;
            Exit;
          end
          else
          begin
            Result := False;
            Exit;
          end;
        end;
      end;
    end;


    Cluster := GetNextCluster(Cluster);
  end;
end;

function ReadFileContent(Cluster: LongWord; Buffer: PAnsiChar; Count: Integer): LongWord;
var
  ClusterOffset: LongWord;
  BytesToRead, TotalBytesRead: LongWord;
  ClusterSize: LongWord;
begin
  TotalBytesRead := 0;
  ClusterSize := SectorsPerCluster *BytesPerSector;

  while (Cluster < EOC_MIN) and (TotalBytesRead < Count) do
  begin
    ClusterOffset := ClusterToLBA(Cluster);
    BytesToRead := Min(ClusterSize, Count - TotalBytesRead);
    if not ReadSector(ClusterOffset, @Buffer[TotalBytesRead], BytesToRead) then
    begin
      WriteLn('Cluster okunurken hata oluþtu.');
      Result := TotalBytesRead;
      Exit;
    end;

    TotalBytesRead := TotalBytesRead + BytesToRead;
    Cluster := GetNextCluster(Cluster);

    if Cluster >= EOC then
      Break;
  end;

  Result := TotalBytesRead;
end;


function WriteFileContent(Cluster: LongWord; Buffer: PAnsiChar;  Count: Integer): LongWord;
var
  ClusterOffset: LongWord;
  BytesToWrite, TotalBytesWritten: LongWord;
  ClusterSize: LongWord;
  NextCluster: LongWord;
begin
  TotalBytesWritten := 0;
  ClusterSize := SectorsPerCluster * BytesPerSector;

  while (Cluster < EOC_MIN) and (TotalBytesWritten < Count) do
  begin
    ClusterOffset := ClusterToLBA(Cluster);
    BytesToWrite := Min(ClusterSize, Count - TotalBytesWritten);

    WriteSector(ClusterOffset, @Buffer[TotalBytesWritten], BytesToWrite);

    TotalBytesWritten := TotalBytesWritten + BytesToWrite;
    NextCluster := GetNextCluster(Cluster);

    if NextCluster >= EOC then
    begin
      if not AllocateNewCluster(NextCluster) then
      begin
        Result := TotalBytesWritten;
        Exit;
      end;

      SetNextCluster(Cluster, NextCluster);
    end;
    Cluster := NextCluster;
  end;

  SetNextCluster(Cluster, EOC);

  Result := TotalBytesWritten;
end;

function CreateFile(FileName: PChar): Boolean;
var
  I, J: integer;
  DirectoryName: array[0..32] of char;
  Cluster: LongWord;
  FoundEntry: TDirectoryEntry;
begin
  Result := False;

  Cluster:=RootCluster ;
  DirectoryName := '';
  I := 0;
  J := 0;
  repeat
    case FileName[i] of
      '/','\':
        begin
         if FindFileEntry(Cluster, PChar(@DirectoryName[0]),FoundEntry) then
         begin
           Cluster:=((FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow);
         end;

          DirectoryName := '';
          J := 0;
        end
        else
        begin
          DirectoryName[J] := FileName[i];
          Inc(J);
        end;
     end;

    Inc(i);
  until FileName[i] = #0;

  Result:=CreateFileContent(Cluster,PChar(@DirectoryName[0]),$20)
end;

function CreateDir(FileName: PChar): Boolean;
var
  I, J: integer;
  DirectoryName: array[0..32] of char;
  Cluster: LongWord;
  FoundEntry: TDirectoryEntry;
begin
  Result := False;
  Cluster:=RootCluster ;
  DirectoryName := '';
  I := 0;
  J := 0;
  repeat
    case FileName[i] of
      '/','\':
        begin
         if FindFileEntry(Cluster, PChar(@DirectoryName[0]),FoundEntry) then
         begin
           Cluster:=((FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow);
         end;

          DirectoryName := '';
          J := 0;
        end
        else
        begin
          DirectoryName[J] := FileName[i];
          Inc(J);
        end;
     end;

    Inc(i);
  until FileName[i] = #0;

  Result:=CreateFileContent(Cluster,PChar(@DirectoryName[0]),$10)
end;

function ReadFile(FileName: PChar ; Buffer:  PAnsiChar;  Count: LongInt=0):Integer;
var
  I, J: integer;
  DirectoryName: array[0..32] of char;
  FoundEntry: TDirectoryEntry;
  CurrentCluster,Cluster: LongWord;
  ConvertedName: array[0..11] of Char;
  FileSize:LongInt;
begin
  Cluster:=RootCluster ;
  DirectoryName := '';
  I := 0;
  J := 0;
  repeat
    case FileName[i] of
      '/','\':
        begin
         if FindFileEntry(Cluster, PChar(@DirectoryName[0]),FoundEntry) then
         begin
           Cluster:=((FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow);
         end;

          DirectoryName := '';
          J := 0;
        end
        else
        begin
          DirectoryName[J] := FileName[i];
          Inc(J);
        end;
     end;

    Inc(i);
  until FileName[i] = #0;


 if FindFileEntry(Cluster, PChar(@DirectoryName[0]) , FoundEntry) then
 begin
    CurrentCluster := (FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow;
    if Count>0 then FileSize:=Count else  FileSize:=FoundEntry.FileSize;
    Result:=  ReadFileContent(CurrentCluster,Buffer,FileSize);
    Exit;
  end;

  Result:=0;
end;


function WriteFile(FileName: PChar; const Buffer: PAnsiChar; Count: LongInt=0): Integer;
var
  DirectoryName: array[0..32] of Char;
  FoundEntry: TDirectoryEntry;
  CurrentCluster, Cluster: LongWord;
  i, j: Integer;
begin
  Cluster := RootCluster;
  i := 0;
  j := 0;
  DirectoryName := '';
  repeat
    case FileName[i] of
      '/','\':
        begin
         if FindFileEntry(Cluster, PChar(@DirectoryName[0]),FoundEntry) then
         begin
           Cluster:=((FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow);
         end;

          DirectoryName := '';
          J := 0;
        end
        else
        begin
          DirectoryName[J] := FileName[i];
          Inc(J);
        end;
     end;

    Inc(i);
  until FileName[i] = #0;


  if FindFileEntry(Cluster, PChar(@DirectoryName[0]), FoundEntry,Count) then
  begin
    CurrentCluster := (FoundEntry.FirstClusterHigh shl 16) or FoundEntry.FirstClusterLow;
    Result := WriteFileContent(CurrentCluster,Buffer,Count);
    Exit;
  end;

  Result := 0;
end;






function FormatFat32Image(const FileName: string; SizeInMB: Integer): Boolean;
var
  Stream: TFileStream;
  BootSector: TBootSector;
  Buffer: array[0..511] of Byte;
  TotalSectors, FATSize: Cardinal;
  i: Integer;
  SectorsPerCluster:Byte;
  BootFileStream : TFileStream;
  BootSectorBin: TBootSector;
  Buffer1: array[0..1000] of Byte;
begin
  Result := False;
  Stream := TFileStream.Create(FileName, fmOpenReadWrite);
  try
    FillChar(BootSector, SizeOf(BootSector), 0);

    TotalSectors := SizeInMB * 1024 * 2;
    SectorsPerCluster:=8;
    FATSize := (TotalSectors div SectorsPerCluster) * 4 div 512;

    BootSector.JumpCode[0] := $EB;
    BootSector.JumpCode[1] := $58;
    BootSector.JumpCode[2] := $90;
    Move('ECODER.1', BootSector.OEMName, 8);
    BootSector.BytesPerSector := 512;
    BootSector.SectorsPerCluster := 8; // 4 KB
    BootSector.ReservedSectors := 32;
    BootSector.NumberOfFATs := 2;
    BootSector.SectorsPerTrack := 63;
    BootSector.NumberOfHeads := 255; // Varsayýlan deðer
    BootSector.Media := $F8;
    BootSector.TotalSectors32 := TotalSectors;
    BootSector.FATSize32 := FATSize;
    BootSector.RootCluster := 2;
    BootSector.FSInfo := 1;
    BootSector.BkBootSec := 6;
    BootSector.DriveNumber := $80;
    BootSector.BootSignature := $29;
    BootSector.VolumeID := $0000;
    Move('ECODER OSV1', BootSector.VolumeLabel, 11);
    Move('FAT32   ', BootSector.FileSystemType, 8);
    BootSector.BootSectorSignature := $AA55;


     BootFileStream := TFileStream.Create('boot/Stage1.bin', fmOpenRead);   //  bootsector
     try
       FillChar(BootSectorBin, SizeOf(TBootSector), 0);
       BootFileStream.Position := 0;
       BootFileStream.ReadBuffer(BootSectorBin, SizeOf(TBootSector));
       Move(BootSectorBin.JumpCode[0], BootSector.JumpCode[0],SizeOf(BootSector.JumpCode));
       Move(BootSectorBin.BootCode[0], BootSector.BootCode[0],SizeOf(BootSectorBin.BootCode));
     finally
     BootFileStream.Free;
     end;



    Stream.Seek(0 * 512, soBeginning);
    Stream.Write(BootSector, SizeOf(TBootSector));



    FillChar(Buffer, SizeOf(Buffer), 0);
    for i := 32 to 32 + 2 * FATSize - 1 do
    begin
       Stream.Seek(i * 512, soBeginning);
       Stream.Write(Buffer, SizeOf(Buffer));
    end;   


    PCardinal(@Buffer[0])^ := $0FFFFFF8;
    PCardinal(@Buffer[4])^ := $0FFFFFFF;
    PCardinal(@Buffer[8])^ := $0FFFFFF8;
    Stream.Seek(32 * 512, soBeginning);
    Stream.Write(Buffer, SizeOf(Buffer));

    Stream.Seek(32 + FATSize * 512, soBeginning);
    Stream.Write(Buffer, SizeOf(Buffer));

    FillChar(Buffer, SizeOf(Buffer), 0);
    PCardinal(@Buffer[0])^ := $41615252;
    PCardinal(@Buffer[484])^ := $61417272;
    PCardinal(@Buffer[488])^ := $FFFFFFFF;
    PCardinal(@Buffer[492])^ := $00000002;
    PWord(@Buffer[510])^ := $AA55;

    Stream.Seek(BootSector.FSInfo * 512, soBeginning);
    Stream.Write(Buffer, SizeOf(Buffer));  

    Result := True;
  finally
    Stream.Free;
  end;
end;

function CreateFat32Image(const FileName: string; SizeInMB: LongWord): Boolean;
var
  Stream: TFileStream;
  Buffer: array[0..511] of Byte;
  TotalSectors, i: LongWord;
begin
  Result := False;
  FillChar(Buffer, SizeOf(Buffer), 0);
  Stream := TFileStream.Create(FileName, fmCreate);
  try
     TotalSectors := SizeInMB * 2048;
     for i := 0 to TotalSectors - 1 do
     begin
        if Stream.Write(Buffer, SizeOf(Buffer)) <> SizeOf(Buffer) then
          Exit;
     end;

     Result := True;
    finally
      Stream.Free;
    end;
end;


Procedure AddFile(SrcFileName:PChar; FileName:PChar);
var
  Stream: TFileStream;
  Buffer:array of byte;
begin
    Stream := TFileStream.Create(SrcFileName, fmOpenRead);
    try
      SetLength(Buffer, Stream.Size);
      Stream.Position := 0;
      Stream.Read(Buffer[0], Stream.Size);
      CreateFile(FileName);
      WriteFile(FileName,@Buffer[0],Stream.Size);

      SetLength(Buffer, 0);
    finally
      Stream.Free;
    end;
end;

procedure AddFiles(const SourceDir, TargetDir, Extension: string);
var
  SearchRec: TSearchRec;
  Found: Integer;
  SourcePath, TargetPath: string;
begin
  // Kaynak klasörün sonuna '\' ekleyelim
  SourcePath := IncludeTrailingPathDelimiter(SourceDir);
  TargetPath := IncludeTrailingPathDelimiter(TargetDir);

  // Belirtilen uzantýya göre arama yap
  Found := FindFirst(SourcePath + '*.' + Extension, faAnyFile, SearchRec);
  try
    while Found = 0 do
    begin
      if (SearchRec.Attr and faArchive <> 0) then
      begin
        AddFile(
          PChar(SourcePath + SearchRec.Name),   // Kaynak dosya
          PChar(TargetPath + SearchRec.Name)    // Hedef dosya
        );
      end;
      Found := FindNext(SearchRec);
    end;
  finally
    FindClose(SearchRec);
  end;
end;









var
  BootSector: TBootSector;
  I:Integer;
  Buffer:array[0..511] of byte;
  BytesRead: LongWord;

begin

// nasm boot.asm -f bin -o bootsector.bin
// nasm Stage2.asm -f bin -o Stage2.bin


 


 CreateFat32Image('Fat32.img', 8);

  // Create FAT32 filesystem
  if FormatFat32Image('Fat32.img',8) then
    Writeln('FAT32 filesystem successfully created on Fat32.img')
  else
    Writeln('Failed to create FAT32 filesystem.');







  
  ImgFile := TFileStream.Create('Fat32.img', fmOpenReadWrite);
  try

    ReadSector(0,@BootSector);
    BytesPerSector:=BootSector.BytesPerSector;
    SectorsPerCluster:=BootSector.SectorsPerCluster;
    ReservedSectors:=BootSector.ReservedSectors;
    NumberOfFATs:=BootSector.NumberOfFATs;
    RootEntryCount:=BootSector.RootEntryCount;
    TotalSectors32:=BootSector.TotalSectors32;
    FATSize32:=BootSector.FATSize32;
    RootCluster:=BootSector.RootCluster;

    AddFile('boot/stage2.bin','stage2.bin');
    AddFile('Kernel/kernel.exe','kernel.exe');

   // AddFile('README.TXT','README.TXT');
    AddFile('Systems.ini','Systems.ini');
   // AddFile('WALL.BMP','WALL.BMP');
   // AddFile('output.jpg','output.jpg');
   // AddFile('Test.jpg','Test.jpg');


    if CreateDir('BIN') then
    begin
       AddFiles(ExtractFilePath(ParamStr(0)) + 'Kernel/Applications', 'BIN', 'exe');
    end;

   if CreateDir('SYSTEM') then
   begin
     AddFiles(ExtractFilePath(ParamStr(0)) + 'Kernel/Applications', 'SYSTEM', 'dll');
        // AddFile('Kernel/Applications/kernel.dll','SYSTEM\Kernel.dll');
        // AddFile('Kernel/Fat32.dll','SYSTEM\DLL\Fat32.dll');
        // AddFile('Kernel/Draw32.dll','SYSTEM\DLL\Draw32.dll');
   end;

   if CreateDir('Images') then
   begin
     AddFiles(ExtractFilePath(ParamStr(0)) + 'Images', 'Images', 'bmp');
   end;

   if CreateDir('Sounds') then
   begin
     AddFiles(ExtractFilePath(ParamStr(0)) + 'Sounds', 'Sounds', 'wav');
   end;

   AddFile('Bios.bin','Bios.bin');
   AddFile('Basic.bin','Basic.bin');
     
   if CreateDir('Games') then
   begin
     AddFile('Games\TETRIS.cp8','Games\TETRIS.cp8');
    // AddFile('Games\BRIX.cp8','Games\BRIX.cp8');
    // AddFile('Games\PONG.cp8','Games\PONG.cp8');
   end;

  finally
    ImgFile.Free;
  end;

  ShellExecute(0, nil, 'cmd.exe', '/C mkisofs -o output.iso -J -R iso', nil, SW_HIDE);
  WriteLn('Tamam');
  ReadLn;

  ShellExecute(0, nil, 'cmd.exe',
  '/C qemu-system-x86_64.exe -cpu core2duo -m 128 -device sb16 ' +
  '-drive format=raw,file=Fat32.img ' +
  '-cdrom output.iso ' +
  '-nic model=rtl8139,id=rtl8139,hostfwd=tcp::8080-:80,hostfwd=udp::7070-:7070,hostfwd=udp::8080-:8080 '+
  '-nic model=ne2k_pci,id=ne2k,hostfwd=tcp::8081-:81,hostfwd=tcp::8082-:82',nil, 0);


 

end.
