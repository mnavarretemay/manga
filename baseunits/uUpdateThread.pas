{
        File: uUpdateThread.pas
        License: GPLv2
        This unit is a part of Free Manga Downloader
}

unit uUpdateThread;

{$mode delphi}

interface

uses
  Classes, SysUtils, typinfo, uData, LazFileUtils, uBaseUnit, uMisc,
  WebsiteModules, DBDataProcess, SimpleTranslator, FMDOptions, httpsendthread, MultiLog;

type
  TUpdateListManagerThread = class;

  { TUpdateListThread }

  TUpdateListThread = class(THTTPThread)
  protected
    Info: TMangaInformation;
    checkStyle: TCheckStyleType;
    workPtr: Integer;
    manager: TUpdateListManagerThread;

    procedure Execute; override;
    procedure DoTerminate; override;
  public
    title, link: String;
    constructor Create;
    destructor Destroy; override;
  end;

  { TUpdateListManagerThread }

  TUpdateListManagerThread = class(THTTPThread)
  private
    FStatus: String;
    FCommitCount: Integer;
    FThreadAborted,
    FThreadEndNormally,
    FIsPreListAvailable: Boolean;
  protected
    procedure Execute; override;
    {$IFNDEF DOWNLOADER}
    procedure ConsoleReport;
    procedure SaveCurrentDatabase;
    {$ENDIF}
    procedure MainThreadStatusRepaint;
    procedure MainThreadShowGetting;
    procedure MainThreadEndGetting;
    procedure MainThreadRemoveFilter;
    procedure ExtractFile;
    procedure RefreshList;
    procedure DlgReport;
    procedure GetInfo(const limit: Integer; const cs: TCheckStyleType);
    procedure DoTerminate; override;
  public
    CS_AddInfoToData, CS_AddNamesAndLinks: TRTLCriticalSection;
    isFinishSearchingForNewManga, isDownloadFromServer, isDoneUpdateNecessary: Boolean;
    mainDataProcess: TDBDataProcess;
    tempDataProcess: TDBDataProcess;
    websites: TStringList;
    website, twebsite, twebsitetemp: String;
    ModuleId: Integer;
    workPtr, directoryCount,
    // for fakku's doujinshi only
    directoryCount2, numberOfThreads, websitePtr: Integer;
    threads: TFPList;
    SortedList, NoMangaInfo: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure CheckCommit(const CommitCount: Integer = 32);
  end;
  
resourcestring
  RS_UpdatingList = 'Updating list';
  RS_GettingDirectory = 'Getting directory';
  RS_LookingForNewTitle = 'Looking for new title(s)';
  RS_LookingForNewTitleFromAnotherDirectory = 'Looking for new title(s) from another directory';
  RS_GettingInfo = 'Getting info';
  RS_GettingListFor = 'Getting list for';
  RS_Preparing = 'Preparing';
  RS_IndexingNewTitle = 'Indexing new title(s)';
  RS_RemovingDuplicateFromNewTitle = 'Removing duplicate from new title(s)';
  RS_RemovingDuplicateFromCurrentData = 'Removing duplicate from current data';
  RS_RemovingDuplicateFromLocalData = 'Removing duplicate from local data';
  RS_SynchronizingData = 'Synchronizing data';
  RS_SavingData = 'Saving data';
  RS_DlgHasNewManga = '%s has %d new manga(s)';

implementation

uses
  frmMain, Dialogs, ComCtrls;

{ TUpdateListThread }

constructor TUpdateListThread.Create;
begin
  inherited Create(True);
end;

destructor TUpdateListThread.Destroy;
begin
  if Assigned(Info) then
    Info.Free;
  inherited Destroy;
end;

procedure TUpdateListThread.Execute;
var
  names, links: TStringList;
  i: Integer;
begin
  try
    if checkStyle = CS_INFO then
      Info := TMangaInformation.Create(Self, True)
    else
      Info := TMangaInformation.Create(Self, False);
    Info.isGetByUpdater := True;
    info.ModuleId := manager.ModuleId;

    case CheckStyle of
      CS_DIRECTORY_COUNT:
      begin
        if manager.ModuleId > -1 then
        begin
          with Modules.Module[manager.ModuleId] do
          for i := Low(TotalDirectoryPage) to High(TotalDirectoryPage) do
          begin
            CurrentDirectoryIndex := i;
            info.GetDirectoryPage(TotalDirectoryPage[i], manager.website);
          end;
        end
        else
        if manager.website = WebsiteRoots[FAKKU_ID, 0] then
        begin
          FAKKU_BROWSER := FAKKU_BROWSER_1;
          info.GetDirectoryPage(manager.directoryCount, manager.website);

          FAKKU_BROWSER := FAKKU_BROWSER_2;
          info.GetDirectoryPage(manager.directoryCount2, manager.website);
        end
        else
          info.GetDirectoryPage(manager.directoryCount, manager.website);
      end;

      //get names and links
      CS_DIRECTORY_PAGE, CS_DIRECTORY_PAGE_2:
      begin
        names := TStringList.Create;
        links := TStringList.Create;
        try
          if BROWSER_INVERT then
          begin
            if manager.ModuleId <> -1 then
            with Modules.Module[manager.ModuleId] do
              workPtr := TotalDirectoryPage[CurrentDirectoryIndex] - workPtr -1
            else
            if checkStyle = CS_DIRECTORY_PAGE then
              workPtr := manager.directoryCount - workPtr - 1
            else
            if checkStyle = CS_DIRECTORY_PAGE_2 then
              workPtr := manager.directoryCount2 - workPtr - 1;
          end;
          if manager.website = WebsiteRoots[FAKKU_ID, 0] then
          begin
            if checkStyle = CS_DIRECTORY_PAGE then
            begin
              FAKKU_BROWSER := FAKKU_BROWSER_1;
              Info.GetNameAndLink(names, links, manager.website, IntToStr(workPtr));
            end
            else
            if checkStyle = CS_DIRECTORY_PAGE_2 then
            begin
              FAKKU_BROWSER := FAKKU_BROWSER_2;
              Info.GetNameAndLink(names, links, manager.website, IntToStr(workPtr));
            end;
          end
          else
            Info.GetNameAndLink(names, links, manager.website, IntToStr(workPtr));

          //if website has sorted list by latest added
          //we will stop at first found against current db
          if links.Count > 0 then
          begin
            EnterCriticalSection(manager.CS_AddNamesAndLinks);
            try
              if manager.FIsPreListAvailable then begin
                for i:=0 to links.Count-1 do begin
                  if manager.mainDataProcess.AddData(names[i],links[i],'','','','','',0,0) then
                    manager.tempDataProcess.AddData(names[i],links[i],'','','','','',0,0)
                  else if (manager.isFinishSearchingForNewManga=False) and manager.SortedList then
                    manager.isFinishSearchingForNewManga:=True;
                end;
                manager.mainDataProcess.Rollback;
              end
              else
                for i:=0 to links.Count-1 do
                  manager.tempDataProcess.AddData(names[i],links[i],'','','','','',0,0);
              manager.tempDataProcess.Commit;
            finally
              LeaveCriticalSection(manager.CS_AddNamesAndLinks);
            end;
          end;
        finally
          names.Free;
          links.Free;
        end;
      end;

      CS_INFO:
      begin
        Info.mangaInfo.title:=title;
        Info.mangaInfo.link:=link;
        if link<>'' then begin
          Info.GetInfoFromURL(manager.website,link,DefaultRetryCount);
          // status = '-1' mean it's not exist and shouldn't be saved to database
          if (not Terminated) and (Info.mangaInfo.status <> '-1') then
          begin
            EnterCriticalSection(manager.CS_AddInfoToData);
            try
              Info.AddInfoToData(title,link,manager.mainDataProcess);
              manager.CheckCommit(manager.numberOfThreads);
            finally
              LeaveCriticalSection(manager.CS_AddInfoToData);
            end;
          end;
        end;
      end;
    end;
  except
    on E: Exception do
    begin
      E.Message := E.Message + LineEnding + LineEnding +
        '  Website : ' + manager.website + LineEnding +
        '  CS      : ' + GetEnumName(TypeInfo(TCheckStyleType), Integer(checkStyle)) + LineEnding;
      if checkStyle = CS_INFO then
      begin
        E.Message := E.Message +
        '  Title   : ' + title + LineEnding +
        '  URL     : ' + link + LineEnding;
      end;
      MainForm.ExceptionHandler(Self, E);
    end;
  end;
end;

procedure TUpdateListThread.DoTerminate;
begin
  LockCreateConnection;
  try
    Modules.DecActiveConnectionCount(manager.ModuleId);
    manager.threads.Remove(Self);
  finally
    UnlockCreateConnection
  end;
  inherited DoTerminate;
end;

{ TUpdateListManagerThread }

procedure TUpdateListManagerThread.MainThreadStatusRepaint;
begin
  MainForm.sbUpdateList.Repaint;
end;

procedure TUpdateListManagerThread.MainThreadShowGetting;
begin
  if MainForm.sbUpdateList.Visible = False then
  begin
    //statusbar reordering based on who's show up first?
    MainForm.sbUpdateList.Height := 30;
    MainForm.sbMain.Hide;
    MainForm.sbUpdateList.Show;
    MainForm.sbUpdateList.Panels[0].Style := psOwnerDraw;
    MainForm.btAbortUpdateList.Show;
    MainForm.sbMain.Show;
  end;
  MainForm.sbMain.SizeGrip := not MainForm.sbUpdateList.Visible;
  MainForm.sbUpdateList.Panels[0].Text := FStatus;
end;

procedure TUpdateListManagerThread.MainThreadEndGetting;
begin
  MainForm.sbUpdateList.Panels[0].Text := '';
  mainForm.sbUpdateList.Panels[0].Style := psText;
  MainForm.sbUpdateList.Hide;
  MainForm.sbMain.SizeGrip := not MainForm.sbUpdateList.Visible;
  MainForm.isUpdating:=False;
  if MainForm.isPendingExitCounter then
    MainForm.DoExitWaitCounter;
end;

procedure TUpdateListManagerThread.MainThreadRemoveFilter;
begin
  MainForm.btRemoveFilterClick(MainForm.btRemoveFilter);
end;

procedure TUpdateListManagerThread.ExtractFile;
var
  Sza, datapath, filepath: String;
begin
  Sza := FMD_DIRECTORY + ZIP_EXE;
  if not FileExistsUTF8(Sza) then Exit;

  datapath := DATA_FOLDER;
  filepath := datapath + website;
  if FileExistsUTF8(filepath + '.7z') then
     filepath += '.7z'
  else
  if FileExistsUTF8(filepath + '.zip') then
    filepath += '.zip';

  if FileExistsUTF8(filepath) then
  begin
    if FileExistsUTF8(datapath + website + DBDATA_EXT) then
      DeleteFileUTF8(datapath + website + DBDATA_EXT);
    if FileExistsUTF8(datapath + website + DATA_EXT) then
      DeleteFileUTF8(datapath + website + DATA_EXT);
    RunExternalProcess(Sza, ['x', filepath, '-o' +
      AnsiQuotedStr(datapath, '"'), '-aoa'], False, True);
    DeleteFileUTF8(filepath);
  end
end;

constructor TUpdateListManagerThread.Create;
begin
  inherited Create(True);
  InitCriticalSection(CS_AddInfoToData);
  InitCriticalSection(CS_AddNamesAndLinks);
  FreeOnTerminate := True;

  websites := TStringList.Create;

  mainDataProcess := TDBDataProcess.Create;
  tempDataProcess := TDBDataProcess.Create;

  threads := TFPList.Create;
  SortedList := False;
  NoMangaInfo := False;
  ModuleId := -1;
  FThreadEndNormally:=False;
  FThreadAborted:=False;
  FIsPreListAvailable:=False;
end;

destructor TUpdateListManagerThread.Destroy;
begin
  if FThreadAborted then Logger.SendWarning(Self.ClassName+', thread aborted by user?');
  if not FThreadEndNormally then Logger.SendWarning(Self.ClassName+', thread doesn''t end normally, ended by user?');
  websites.Free;
  mainDataProcess.Close;
  tempDataProcess.Close;
  DeleteDBDataProcess(twebsite);
  DeleteDBDataProcess(twebsitetemp);
  mainDataProcess.Free;
  tempDataProcess.Free;
  threads.Free;
  MainForm.isUpdating := False;
  DoneCriticalsection(CS_AddInfoToData);
  DoneCriticalsection(CS_AddNamesAndLinks);
  inherited Destroy;
end;

procedure TUpdateListManagerThread.CheckCommit(const CommitCount: Integer);
begin
  Inc(FCommitCount);
  if FCommitCount >= CommitCount then
  begin
    FCommitCount := 0;
    if Assigned(mainDataProcess) then
      mainDataProcess.Commit;
  end;
end;

procedure TUpdateListManagerThread.RefreshList;
begin
  try
    with MainForm do
    begin
      if cbSelectManga.Items[cbSelectManga.ItemIndex] = website then
      begin
        vtMangaList.Clear;
        if dataProcess = nil then
          dataProcess := TDBDataProcess.Create
        else
          dataProcess.Close;
        if isDownloadFromServer then
          ExtractFile
        else
          OverwriteDBDataProcess(website, twebsite);
        OpenDataDB(website);
      end
      else
      begin
        if dataProcess.WebsiteLoaded(website) then
          dataProcess.RemoveFilter;
        if isDownloadFromServer then
          ExtractFile
        else
          OverwriteDBDataProcess(website, twebsite);
      end;
    end;
  except
    on E: Exception do
      MainForm.ExceptionHandler(Self, E);
  end;
end;

procedure TUpdateListManagerThread.DlgReport;
begin
  MessageDlg('', Format(RS_DlgHasNewManga, [website, tempDataProcess.RecordCount]),
    mtInformation, [mbYes], 0);
end;

procedure TUpdateListManagerThread.GetInfo(const limit: Integer;
  const cs: TCheckStyleType);

  procedure WaitForThreads;
  begin
    while (not Terminated) and (threads.Count > 0) do
      Sleep(SOCKHEARTBEATRATE);
  end;

var
  mt, i: Integer;
  s: String;
begin
  MainForm.ulTotalPtr := limit;
  try
    while (not Terminated) and (workPtr < limit) do begin
      mt := advancedfile.ReadInteger('UpdateListNumberOfThreads', website, -1);
      if mt > 0 then
      begin
        if mt > MAX_CONNECTIONPERHOSTLIMIT then //32 is max | be carefull, there's still memory leak problems
          mt := MAX_CONNECTIONPERHOSTLIMIT;
        numberOfThreads := mt;
      end
      else
      begin
        if Modules.MaxConnectionLimit[ModuleId] > 0 then
          numberOfThreads := Modules.MaxConnectionLimit[ModuleId]
        else
          numberOfThreads := OptionMaxThreads;
        if numberOfThreads > OptionMaxThreads then
          numberOfThreads := OptionMaxThreads;
      end;
      if numberOfThreads < 1 then
        numberOfThreads := 1;  //default

      // Finish searching for new series
      if (cs in [CS_DIRECTORY_PAGE, CS_DIRECTORY_PAGE_2]) and
        (isFinishSearchingForNewManga) then
      begin
        WaitForThreads;
        workPtr := limit;
        Exit;
      end;

      if Modules.MaxConnectionLimit[ModuleId] > 0 then
        while (not Terminated) and (Modules.ActiveConnectionCount[ModuleId] >= numberOfThreads) do
          Sleep(SOCKHEARTBEATRATE)
      else
        while (not Terminated) and (threads.Count >= numberOfThreads) do
          Sleep(SOCKHEARTBEATRATE);

      if (not Terminated) and (threads.Count < numberOfThreads) then
      begin
        LockCreateConnection;
        try
          if Modules.ActiveConnectionCount[ModuleId] >= numberOfThreads then Exit;
          Modules.IncActiveConnectionCount(ModuleId);
          i:=threads.Add(TUpdateListThread.Create);
          if cs=CS_INFO then begin
            TUpdateListThread(threads[i]).title:=tempDataProcess.Value[workPtr,0];
            TUpdateListThread(threads[i]).link:=tempDataProcess.Value[workPtr,1];
          end;
          TUpdateListThread(threads[i]).checkStyle:=cs;
          TUpdateListThread(threads[i]).manager:=Self;
          TUpdateListThread(threads[i]).workPtr:=Self.workPtr;
          TUpdateListThread(threads[i]).Start;
          Inc(workPtr);
          s := RS_UpdatingList + Format(' [%d/%d] %s | [T:%d] [%d/%d]',
            [websitePtr, websites.Count, website, threads.Count, workPtr, limit]);

          case cs of
            CS_DIRECTORY_COUNT:
              begin
                if limit = 1 then
                  s := RS_UpdatingList + Format(' [%d/%d] ', [websitePtr, websites.Count]) +
                    website + ' | ' + RS_GettingDirectory + '...'
                else
                  s := s + ' | ' + RS_GettingDirectory + '...';
              end;
            CS_DIRECTORY_PAGE:
              begin
                s += ' | ' + RS_LookingForNewTitle;
                if ModuleId <> -1 then
                  with Modules.Module[ModuleId] do
                    s += Format(' %d/%d', [CurrentDirectoryIndex + 1, TotalDirectory]);
                s += '...';
              end;
            CS_DIRECTORY_PAGE_2:
              s := s + ' | ' + RS_LookingForNewTitleFromAnotherDirectory + '...';
            CS_INFO:
              s := Format('%s | %s "%s"', [s, RS_GettingInfo, tempDataProcess.Value[workPtr-1,0]]);
          end;
          FStatus := s;
          MainForm.ulWorkPtr := workPtr + 1;
          Synchronize(MainThreadShowGetting);
        finally
          UnlockCreateConnection;
        end;
      end;
    end;
  except
    on E: Exception do
      MainForm.ExceptionHandler(Self, E);
  end;
  WaitForThreads;
end;

procedure TUpdateListManagerThread.DoTerminate;
var
  i: Integer;
begin
  if threads.Count > 0 then
  begin
    LockCreateConnection;
    try
      for i := 0 to threads.Count - 1 do
        TUpdateListThread(threads[i]).Terminate;
    finally
      UnlockCreateConnection;
    end;
    while threads.Count > 0 do
      Sleep(SOCKHEARTBEATRATE);
  end;
  inherited DoTerminate;
end;

procedure TUpdateListManagerThread.Execute;
var
  j, k: Integer;
  cloghead: String;
begin
  if websites.Count = 0 then
    Exit;
  try
    websitePtr := 0;
    if isDownloadFromServer then
    begin
      while websitePtr < websites.Count do
      begin
        website := websites.Strings[websitePtr];
        Inc(websitePtr);
        FStatus := RS_GettingListFor + ' ' + website + ' ...';
        Synchronize(MainThreadShowGetting);
        RunExternalProcess(FMD_DIRECTORY + UPDATER_EXE, ['-r' , '3', '-d',
          GetMangaDatabaseURL(website), '--lang', SimpleTranslator.LastSelected]);
        Synchronize(RefreshList);
      end;
    end
    else
      while websitePtr < websites.Count do
      begin
        FThreadAborted:=True;
        website := websites.Strings[websitePtr];
        ModuleId := Modules.LocateModule(website);
        SortedList := SitesWithSortedList(website);
        NoMangaInfo := SitesWithoutInformation(website);
        Inc(websitePtr);

        cloghead:=Self.ClassName+', '+website+': ';
        FStatus := RS_UpdatingList + Format(' [%d/%d] %s',
          [websitePtr, websites.Count, website]) + ' | ' + RS_Preparing + '...';
        Synchronize(MainThreadShowGetting);

        twebsite:='__'+website;
        twebsitetemp:=twebsite+'_templist';
        try
          DeleteDBDataProcess(twebsite);
          DeleteDBDataProcess(twebsitetemp);
          if (MainForm.dataProcess.Website = website) and
            (MainForm.dataProcess.Connected) then
            MainForm.dataProcess.Backup(twebsite)
          else
          begin
            if MainForm.dataProcess.WebsiteLoaded(website) then
              Synchronize(MainThreadRemoveFilter);
            CopyDBDataProcess(website, twebsite);
          end;

          if not mainDataProcess.Connect(twebsite) then
            mainDataProcess.CreateDatabase(twebsite);
          tempDataProcess.CreateDatabase(twebsitetemp);

          // get directory page count
          directoryCount := 0;
          directoryCount2 := 0;
          workPtr := 0;
          GetInfo(1, CS_DIRECTORY_COUNT);
          if Terminated then Break;

          mainDataProcess.OpenTable('',True);
          FIsPreListAvailable:=mainDataProcess.RecordCount>0;
          mainDataProcess.CloseTable;

          // get names and links
          workPtr := 0;
          isFinishSearchingForNewManga := False;
          if ModuleId <> -1 then
          begin
            with Modules.Module[ModuleId] do
            for j := Low(TotalDirectoryPage) to High(TotalDirectoryPage) do
            begin
              workPtr := 0;
              isFinishSearchingForNewManga := False;
              CurrentDirectoryIndex := j;
              GetInfo(TotalDirectoryPage[j], CS_DIRECTORY_PAGE);
            end;
          end
          else
          if website = WebsiteRoots[FAKKU_ID, 0] then
          begin
            if directoryCount = 0 then
              directoryCount := 1;
            GetInfo(directoryCount, CS_DIRECTORY_PAGE);
            workPtr := 0;
            isFinishSearchingForNewManga := False;
            if directoryCount2 = 0 then
              directoryCount2 := 1;
            GetInfo(directoryCount2, CS_DIRECTORY_PAGE_2);
          end
          else
            GetInfo(directoryCount, CS_DIRECTORY_PAGE);

          if Terminated then Break;

          FStatus := RS_UpdatingList + Format(' [%d/%d] %s',
            [websitePtr, websites.Count, website]) + ' | ' + RS_IndexingNewTitle + '...';
          Synchronize(MainThreadShowGetting);

          tempDataProcess.OpenTable('', True);

          // get manga info
          if tempDataProcess.RecordCount>0 then
          begin
            workPtr := 0;
            FCommitCount := 0;
            if NoMangaInfo or
              OptionUpdateListNoMangaInfo then
            begin
              Inc(workPtr);
              for k:=0 to tempDataProcess.RecordCount-1 do
              begin
                mainDataProcess.AddData(
                  tempDataProcess.Value[k,0],
                  tempDataProcess.Value[k,1],
                  '',
                  '',
                  '',
                  '',
                  '',
                  0,
                  Now
                  );
                CheckCommit(5000);
              end;
            end
            else
              GetInfo(tempDataProcess.RecordCount, CS_INFO);
            mainDataProcess.Commit;

            if (workPtr > 0) and (not (Terminated and SortedList)) then
            begin
              FStatus := RS_UpdatingList + Format(' [%d/%d] %s',
                [websitePtr, websites.Count, website]) + ' | ' + RS_SavingData + '...';
              Synchronize(MainThreadShowGetting);
              mainDataProcess.Sort;
              mainDataProcess.Close;
              Synchronize(RefreshList);
            end;
          end;
        except
          on E: Exception do
            Logger.SendException(cloghead + 'error occured!', E);
        end;

        tempDataProcess.Close;
        mainDataProcess.Close;
        DeleteDBDataProcess(twebsite);
        DeleteDBDataProcess(twebsitetemp);

        if Terminated then
          Break;
        websites[websitePtr - 1] := UTF8Encode(#$2714) + websites[websitePtr - 1];
        FThreadAborted:=False;
      end;
  except
    on E: Exception do
      MainForm.ExceptionHandler(Self, E);
  end;
  FThreadEndNormally:=True;
  Synchronize(MainThreadEndGetting);
end;

end.
