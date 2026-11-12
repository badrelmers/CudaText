(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

Copyright (c) Alexey Torgashin
*)
unit proc_markdown_hilite;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics,
  MarkDown.CanvasRender,
  ec_SyntAnal;

type
  { TMarkdownHiliter }

  TMarkdownHiliter = class
  public
    procedure DoHiliteCode(Sender: TObject; const aInfo: utf8string;
      const aCode: utf8string; aTokens: TMarkdownHiliteTokenList);
  end;

function GetMarkdownHiliter: TMarkdownHiliter;
function MarkdownHiliteEnabled: boolean;
procedure SetMarkdownHiliteEnabled(AValue: boolean);

implementation

uses
  Math,
  syncobjs,
  ATStringProc_TextBuffer,
  ec_LexerList,
  ec_syntax_format,
  proc_globdata;

type
  { TMDClientFreer }

  TMDClientFreer = class(TThread)
  //Frees a retired TecClientSyntAnalyzer (and its text buffer) off the UI
  //thread: the analyzer's destructor joins its parser thread, which polls
  //the termination flag every ~100 msec - too slow to run in a paint cycle
  public
    Client: TecClientSyntAnalyzer;
    Buf: TATStringBuffer;
    procedure Execute; override;
  end;

var
  GHiliteEnabled: boolean = true;
  GHiliter: TMarkdownHiliter = nil;
  GSection: TCriticalSection = nil;
  // cache of the last tokenized code block: layout is recalculated
  // on every resize, we don't want to re-run the lexer each time
  GCachedInfo: utf8string = '';
  GCachedCode: utf8string = '';
  GCachedOk: boolean = false;
  GCachedItems: array of TMarkdownHiliteToken;

procedure TMDClientFreer.Execute;
var
  C: TecClientSyntAnalyzer;
  B: TATStringBuffer;
begin
  C:= Client;
  B:= Buf;
  Client:= nil;
  Buf:= nil;
  GSection.Enter;
  try
    C.Free;
    B.Free;
  finally
    GSection.Leave;
  end;
end;

function GetMarkdownHiliter: TMarkdownHiliter;
begin
  if GHiliter=nil then
    GHiliter:= TMarkdownHiliter.Create;
  Result:= GHiliter;
end;

function MarkdownHiliteEnabled: boolean;
begin
  Result:= GHiliteEnabled;
end;

procedure SetMarkdownHiliteEnabled(AValue: boolean);
begin
  GHiliteEnabled:= AValue;
end;

function MDHilite_Utf8CharLen(B: byte): integer; inline;
begin
  if B<$80 then
    Result:= 1
  else if (B and $E0)=$C0 then
    Result:= 2
  else if (B and $F0)=$E0 then
    Result:= 3
  else
    Result:= 4;
end;

function MDHilite_FindLexer(const aInfo: utf8string): TecSyntAnalyzer;
var
  AnNotCorrect: TecSyntAnalyzer;
begin
  Result:= nil;
  if aInfo='' then exit;
  if AppManager=nil then exit;
  if AppManager.LexerCount=0 then exit;

  // 1) aliases from data/lexlib/aliases.ini, e.g. 'py' -> Python;
  // this call also applies the syntax theme to the lexer
  Result:= AppManager.FindLexerByAlias(LowerCase(aInfo));
  if Result<>nil then exit;

  // 2) lexer name, e.g. 'Python', 'C++'
  Result:= AppManager.FindLexerByName(aInfo);
  if Result<>nil then exit;

  // 3) extension, e.g. 'py' as in 'file.py'
  if Pos('/', aInfo)=0 then
    Result:= AppManager.FindLexerByFilename('x.'+aInfo, nil);

  if Result<>nil then
    if Assigned(EControlOptions.OnLexerApplyTheme) then
      EControlOptions.OnLexerApplyTheme(Result, AnNotCorrect);
end;

procedure MDHilite_FreeClientAsync(Client: TecClientSyntAnalyzer; Buf: TATStringBuffer);
var
  Freer: TMDClientFreer;
begin
  if (Client=nil) and (Buf=nil) then exit;
  try
    //create suspended: Execute must not read the fields before they are set
    Freer:= TMDClientFreer.Create(true);
    Freer.FreeOnTerminate:= true;
    Freer.Client:= Client;
    Freer.Buf:= Buf;
    Freer.Start;
  except
    //could not spawn the freer thread: free here, blocking
    FreeAndNil(Freer);
    Client.Free;
    Buf.Free;
  end;
end;

procedure MDHilite_Tokenize(An: TecSyntAnalyzer; const aCode: utf8string);
var
  Buf: TATStringBuffer;
  Client: TecClientSyntAnalyzer;
  Tokens: TecTokenList;
  Token: PecSyntToken;
  St: TecSyntaxFormat;
  StrU16: UnicodeString;
  MapU16ToU8: array of integer;
  i, N, i8, i16, CharLen, ByteLen: integer;
  NPosU8, NLenU8: integer;
begin
  SetLength(GCachedItems, 0);

  StrU16:= UnicodeString(aCode);
  if StrU16='' then exit;
  ByteLen:= length(aCode);

  // map UTF-16 unit index (0-based) -> UTF-8 byte offset (0-based)
  SetLength(MapU16ToU8, length(StrU16)+1);
  for i:= 0 to High(MapU16ToU8) do
    MapU16ToU8[i]:= ByteLen;
  MapU16ToU8[0]:= 0;

  i8:= 1;
  i16:= 0;
  while i8<=ByteLen do
  begin
    CharLen:= MDHilite_Utf8CharLen(byte(aCode[i8]));
    Inc(i8, CharLen);
    if CharLen=4 then
      Inc(i16, 2)
    else
      Inc(i16, 1);
    if i16<=High(MapU16ToU8) then
      MapU16ToU8[i16]:= i8-1;
    if (CharLen=4) and (i16-1>0) and (i16-1<=High(MapU16ToU8)) then
      // middle of a surrogate pair: map to the end of the char
      MapU16ToU8[i16-1]:= i8-1;
  end;

  if GSection=nil then
    GSection:= TCriticalSection.Create;

  Buf:= TATStringBuffer.Create;
  Buf.SetupSlow(StrU16);
  Client:= nil;

  GSection.Enter;
  try
    try
      Client:= TecClientSyntAnalyzer.Create(An, Buf);
    except
      Client:= nil;
    end;

    if Client<>nil then
    try
      //synchronous full parse, fills PublicData.Tokens
      Client.ParseInThread;

      Tokens:= Client.PublicData.Tokens;
      if Tokens<>nil then
        for i:= 0 to Tokens.Count-1 do
        begin
          if not Tokens.IsIndexValid(i) then Continue;
          Token:= Tokens._GetItemPtr(i);
          if Token=nil then Continue;

          St:= Token^.Style;
          if St=nil then Continue;
          if not (St.FormatType in [ftCustomFont, ftFontAttr, ftColor]) then Continue;
          if St.Font=nil then Continue;
          if St.Font.Color=clNone then Continue;

          if (Token^.Range.StartPos<0) or (Token^.Range.StartPos>High(MapU16ToU8)) then Continue;
          if (Token^.Range.EndPos<0) or (Token^.Range.EndPos>High(MapU16ToU8)) then Continue;
          if Token^.Range.EndPos<=Token^.Range.StartPos then Continue;

          NPosU8:= MapU16ToU8[Token^.Range.StartPos]+1; //1-based
          NLenU8:= MapU16ToU8[Token^.Range.EndPos]-(NPosU8-1);
          if NLenU8<=0 then Continue;
          if NPosU8+NLenU8-1>ByteLen then Continue;

          N:= length(GCachedItems);
          SetLength(GCachedItems, N+1);
          GCachedItems[N].Pos:= NPosU8;
          GCachedItems[N].Len:= NLenU8;
          GCachedItems[N].Color:= St.Font.Color;
          GCachedItems[N].Styles:= [];
          if St.FormatType in [ftCustomFont, ftFontAttr] then
            GCachedItems[N].Styles:= St.Font.Style;
        end;
    finally
      //free the analyzer in background: its destructor joins the parser
      //thread (polls every ~100 msec), too slow for the UI thread;
      //the buffer goes with it, the client's destructor marks it invalid
      MDHilite_FreeClientAsync(Client, Buf);
      Client:= nil;
    end;
  finally
    GSection.Leave;
  end;
end;

{ TMarkdownHiliter }

procedure TMarkdownHiliter.DoHiliteCode(Sender: TObject; const aInfo: utf8string;
  const aCode: utf8string; aTokens: TMarkdownHiliteTokenList);
var
  An: TecSyntAnalyzer;
  i: integer;
begin
  if not GHiliteEnabled then exit;
  if aInfo='' then exit;
  if aCode='' then exit;
  if aTokens=nil then exit;

  if GCachedOk and (GCachedInfo=aInfo) and (GCachedCode=aCode) then
  begin
    for i:= 0 to High(GCachedItems) do
      aTokens.Add(GCachedItems[i].Pos, GCachedItems[i].Len,
        GCachedItems[i].Color, GCachedItems[i].Styles);
    exit;
  end;

  SetLength(GCachedItems, 0);
  GCachedOk:= false;
  GCachedInfo:= aInfo;
  GCachedCode:= aCode;

  An:= MDHilite_FindLexer(aInfo);
  if An<>nil then
    MDHilite_Tokenize(An, aCode);
  //cache also the negative result, to not search for the lexer again
  GCachedOk:= true;

  for i:= 0 to High(GCachedItems) do
    aTokens.Add(GCachedItems[i].Pos, GCachedItems[i].Len,
      GCachedItems[i].Color, GCachedItems[i].Styles);
end;

finalization
  FreeAndNil(GHiliter);
  //GSection is not freed here: a pending freer thread may still use it,
  //the OS releases the memory at process exit

end.
