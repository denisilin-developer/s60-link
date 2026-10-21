#include <aknapp.h>
#include <akndoc.h>
#include <aknappui.h>
#include <apgtask.h>
#include <apgcli.h>
#include <aknsbasicbackgroundcontrolcontext.h>
#include <aknsdrawutils.h>
#include <aknsconstants.h>
#include <aknsutils.h>
#include <aknutils.h>
#include <avkon.hrh>
#include <avkon.rsg>
#include <bautils.h>
#include <coecntrl.h>
#include <eikbtgpc.h>
#include <eikenv.h>
#include <eikmenup.h>
#include <eikstart.h>
#include <es_sock.h>
#include <f32file.h>
#include <fbs.h>
#include <in_sock.h>
#include <sysutil.h>
#include <utf.h>
#include <w32std.h>
#include <msvapi.h>
#include <msvids.h>
#include <mtclreg.h>
#include <smsclnt.h>
#include <smuthdr.h>
#include <smut.h>
#include <rsendas.h>
#include <rsendasmessage.h>
#include <txtrich.h>

#include <s60link.rsg>
#include "s60link.hrh"

const TUid KUidS60Link = {0xE7E1E002};
const TUint KPort = 5715;
const TInt KChunk = 32768;

enum TLinkState { EStateStarting, EStateListening, EStateClient, EStateFailed };

struct TLinkStatus
    {
    TInt iState;
    TBuf<40> iAddress;
    TBuf<40> iClient;
    TBuf<120> iLast;
    };

static RCriticalSection gLock;
static TLinkStatus gStatus;
static volatile TBool gStop;

static void SetState(TInt aState, const TDesC &aLast)
{
    gLock.Wait();
    gStatus.iState = aState;
    gStatus.iLast = aLast.Left(gStatus.iLast.MaxLength());
    if (aState != EStateClient)
        gStatus.iClient.Zero();
    gLock.Signal();
}

static void SetLast(const TDesC &aLast)
{
    gLock.Wait();
    gStatus.iLast = aLast.Left(gStatus.iLast.MaxLength());
    gLock.Signal();
}


class CLinkSession : public CBase
{
public:
    CLinkSession(RSocket &aSock, RFs &aFs, TRequestStatus &aNext)
        : iSock(aSock), iFs(aFs), iNext(aNext) {}
    ~CLinkSession()
    {
        delete iChunk;
        iTimer.Close();
    }
    void ConstructL()
    {
        iChunk = HBufC8::NewL(KChunk);
        User::LeaveIfError(iTimer.CreateLocal());
    }
    void RunL();

private:
    TInt Fill();
    TInt Wait(TRequestStatus &aIo, TBool aRecv);
    TInt ReadLine(TDes8 &aLine);
    TInt ReadExact(TDes8 &aOut, TInt aLen);
    TInt Send(const TDesC8 &aData);
    TInt SendOk(const TDesC8 &aBody);
    TInt SendErr(const TDesC &aWhat, TInt aErr);
    TInt Dispatch(const TDesC8 &aLine);
    TInt Hello();
    TInt Drives();
    TInt List(const TDesC &aPath);
    TInt Get(const TDesC &aPath);
    TInt Put(const TDesC &aPath, TInt aSize);
    TInt Install(const TDesC &aPath);
    TInt Shot();
    TInt SmsList(TInt aLimit);
    TInt SmsSend(const TDesC &aTo, const TDesC8 &aText);
    TInt SmsChange(const TDesC8 &aId, TBool aDelete);

    RSocket &iSock;
    RFs &iFs;
    TRequestStatus &iNext;
    RTimer iTimer;
    TBuf8<4096> iBuf;
    TInt iPos;
    HBufC8 *iChunk;
};

TInt CLinkSession::Fill()
{
    if (iPos < iBuf.Length())
        return KErrNone;
    TRequestStatus st;
    TSockXfrLength len;
    iBuf.Zero();
    iPos = 0;
    iSock.RecvOneOrMore(iBuf, 0, st, len);
    TInt err = Wait(st, ETrue);
    if (err != KErrNone)
        return err;
    return iBuf.Length() ? KErrNone : KErrEof;
}

TInt CLinkSession::Wait(TRequestStatus &aIo, TBool aRecv)
{
    TRequestStatus timer;
    iTimer.After(timer, 120000000);
    for (;;) {
        User::WaitForAnyRequest();
        if (aIo.Int() != KRequestPending) {
            iTimer.Cancel();
            User::WaitForRequest(timer);
            return aIo.Int();
        }
        TBool timedOut = timer.Int() != KRequestPending;
        TBool replaced = iNext.Int() != KRequestPending;
        if (!timedOut && !replaced)
            continue;
        if (replaced)
            RThread().RequestSignal();
        if (!timedOut) {
            iTimer.Cancel();
            User::WaitForRequest(timer);
        }
        if (aRecv)
            iSock.CancelRecv();
        else
            iSock.CancelWrite();
        User::WaitForRequest(aIo);
        return timedOut ? KErrTimedOut : KErrServerBusy;
    }
}

TInt CLinkSession::ReadLine(TDes8 &aLine)
{
    aLine.Zero();
    for (;;) {
        TInt err = Fill();
        if (err != KErrNone)
            return err;
        TUint8 c = iBuf[iPos++];
        if (c == '\n')
            return KErrNone;
        if (aLine.Length() == aLine.MaxLength())
            return KErrOverflow;
        aLine.Append(c);
    }
}

TInt CLinkSession::ReadExact(TDes8 &aOut, TInt aLen)
{
    aOut.Zero();
    while (aOut.Length() < aLen) {
        TInt err = Fill();
        if (err != KErrNone)
            return err;
        TInt n = Min(aLen - aOut.Length(), iBuf.Length() - iPos);
        aOut.Append(iBuf.Mid(iPos, n));
        iPos += n;
    }
    return KErrNone;
}

TInt CLinkSession::Send(const TDesC8 &aData)
{
    TRequestStatus st;
    iSock.Write(aData, st);
    return Wait(st, EFalse);
}

TInt CLinkSession::SendOk(const TDesC8 &aBody)
{
    TBuf8<32> head;
    head.Format(_L8("OK\t%d\n"), aBody.Length());
    TInt err = Send(head);
    return err == KErrNone && aBody.Length() ? Send(aBody) : err;
}

TInt CLinkSession::SendErr(const TDesC &aWhat, TInt aErr)
{
    TBuf8<160> line;
    line.Copy(_L8("ERR\t"));
    TBuf8<120> what;
    CnvUtfConverter::ConvertFromUnicodeToUtf8(what, aWhat.Left(40));
    line.Append(what);
    line.AppendFormat(_L8(" (%d)\n"), aErr);
    return Send(line);
}

static void Utf8ToPath(const TDesC8 &aIn, TDes &aOut)
{
    aOut.Zero();
    if (CnvUtfConverter::ConvertToUnicodeFromUtf8(aOut, aIn.Left(Min(aIn.Length(), 200))) < 0)
        aOut.Copy(aIn.Left(aOut.MaxLength()));
}

static void AppendEscaped(RBuf8 &aBuf, const TDesC &aText)
{
    HBufC8 *u = NULL;
    TRAPD(err, u = CnvUtfConverter::ConvertFromUnicodeToUtf8L(aText));
    if (err != KErrNone)
        return;
    TInt need = u->Length() * 2 + 64;
    if (aBuf.MaxLength() - aBuf.Length() < need)
        aBuf.ReAlloc(aBuf.MaxLength() * 2 + need);
    for (TInt i = 0; i < u->Length(); i++) {
        TUint8 c = (*u)[i];
        if (c == '\\')
            aBuf.Append(_L8("\\\\"));
        else if (c == '\n')
            aBuf.Append(_L8("\\n"));
        else if (c == '\t')
            aBuf.Append(_L8("\\t"));
        else if (c != '\r')
            aBuf.Append(c);
    }
    delete u;
}

static HBufC *UnescapeLC(const TDesC8 &aIn)
{
    HBufC8 *raw = HBufC8::NewLC(aIn.Length());
    TPtr8 r = raw->Des();
    for (TInt i = 0; i < aIn.Length(); i++) {
        TUint8 c = aIn[i];
        if (c == '\\' && i + 1 < aIn.Length()) {
            TUint8 n = aIn[++i];
            r.Append(n == 'n' ? '\n' : n == 't' ? '\t' : n);
        } else {
            r.Append(c);
        }
    }
    HBufC *out = CnvUtfConverter::ConvertToUnicodeFromUtf8L(*raw);
    CleanupStack::PopAndDestroy(raw);
    CleanupStack::PushL(out);
    return out;
}

class TQuietObserver : public MMsvSessionObserver
{
public:
    void HandleSessionEventL(TMsvSessionEvent, TAny *, TAny *, TAny *) {}
};

static void AppendUtf8(RBuf8 &aBuf, const TDesC &aText)
{
    TBuf8<512> u;
    CnvUtfConverter::ConvertFromUnicodeToUtf8(u, aText.Left(170));
    if (aBuf.MaxLength() - aBuf.Length() < u.Length() + 64)
        aBuf.ReAlloc(aBuf.MaxLength() * 2 + u.Length() + 64);
    aBuf.Append(u);
}

static TInt64 UnixTime(const TTime &aTime)
{
    TTime epoch(_L("19700000:"));
    return (aTime.Int64() - epoch.Int64()) / 1000000;
}

TInt CLinkSession::Hello()
{
    TBuf<KSysUtilVersionTextLength> sw;
    if (SysUtil::GetSWVersion(sw) != KErrNone)
        sw.Zero();
    for (TInt i = 0; i < sw.Length(); i++)
        if (sw[i] == '\n')
            sw[i] = '|';
    RBuf8 body;
    body.Create(256);
    body.Append(_L8("S60Link\t1\t"));
    AppendUtf8(body, sw);
    TInt err = SendOk(body);
    body.Close();
    return err;
}

TInt CLinkSession::Drives()
{
    TDriveList list;
    TInt err = iFs.DriveList(list);
    if (err != KErrNone)
        return SendErr(_L("drive list"), err);
    RBuf8 body;
    body.Create(512);
    for (TInt d = 0; d < KMaxDrives; d++) {
        TVolumeInfo vol;
        if (!list[d] || d == EDriveD || iFs.Volume(vol, d) != KErrNone)
            continue;
        TChar letter;
        RFs::DriveToChar(d, letter);
        body.AppendFormat(_L8("%c\t%Ld\t%Ld\t"), TUint(letter), vol.iFree, vol.iSize);
        AppendUtf8(body, vol.iName);
        body.AppendFormat(_L8("\t%d\n"), (vol.iDrive.iMediaAtt & KMediaAttWriteProtected) ||
                                              d == EDriveZ ? 1 : 0);
    }
    err = SendOk(body);
    body.Close();
    return err;
}

TInt CLinkSession::List(const TDesC &aPath)
{
    TFileName path(aPath);
    if (!path.Length() || path[path.Length() - 1] != '\\')
        path.Append('\\');
    CDir *dir = NULL;
    TInt err = iFs.GetDir(path, KEntryAttMaskSupported, ESortByName | EDirsFirst, dir);
    if (err != KErrNone)
        return SendErr(path, err);
    RBuf8 body;
    body.Create(4096);
    for (TInt i = 0; i < dir->Count(); i++) {
        const TEntry &e = (*dir)[i];
        body.AppendFormat(_L8("%c\t%d\t%Ld\t"), e.IsDir() ? 'd' : 'f', e.iSize,
                          UnixTime(e.iModified));
        AppendUtf8(body, e.iName);
        body.Append('\n');
    }
    delete dir;
    err = SendOk(body);
    body.Close();
    return err;
}

TInt CLinkSession::Get(const TDesC &aPath)
{
    RFile f;
    TInt err = f.Open(iFs, aPath, EFileRead | EFileShareReadersOrWriters);
    if (err != KErrNone)
        return SendErr(aPath, err);
    TInt size = 0;
    f.Size(size);
    TBuf8<32> head;
    head.Format(_L8("OK\t%d\n"), size);
    err = Send(head);
    TPtr8 chunk = iChunk->Des();
    for (TInt done = 0; err == KErrNone && done < size; done += chunk.Length()) {
        err = f.Read(chunk, Min(KChunk, size - done));
        if (err == KErrNone && chunk.Length() == 0)
            err = KErrCorrupt;
        if (err == KErrNone)
            err = Send(chunk);
    }
    f.Close();
    if (err == KErrNone) {
        TBuf<120> t(_L("Sent "));
        t.Append(TParsePtrC(aPath).NameAndExt().Left(100));
        SetLast(t);
    }
    return err == KErrNone ? KErrNone : KErrAbort;
}

TInt CLinkSession::Put(const TDesC &aPath, TInt aSize)
{
    TFileName part(aPath.Left(KMaxFileName - 8));
    part.Append(_L(".s60part"));
    RFile f;
    TInt err = f.Replace(iFs, part, EFileWrite);
    TPtr8 chunk = iChunk->Des();
    for (TInt done = 0; done < aSize; done += chunk.Length()) {
        TInt rerr = ReadExact(chunk, Min(KChunk, aSize - done));
        if (rerr != KErrNone) {
            if (err == KErrNone)
                f.Close();
            iFs.Delete(part);
            return rerr;
        }
        if (err == KErrNone)
            err = f.Write(chunk);
    }
    if (err == KErrNone) {
        f.Close();
        iFs.SetAtt(aPath, 0, KEntryAttReadOnly);
        iFs.Delete(aPath);
        err = iFs.Rename(part, aPath);
    }
    if (err != KErrNone) {
        iFs.Delete(part);
        return SendErr(aPath, err);
    }
    TBuf<120> t(_L("Received "));
    t.Append(TParsePtrC(aPath).NameAndExt().Left(100));
    SetLast(t);
    return SendOk(KNullDesC8);
}

TInt CLinkSession::Install(const TDesC &aPath)
{
    RApaLsSession ls;
    TInt err = ls.Connect();
    if (err == KErrNone) {
        TThreadId id;
        err = ls.StartDocument(aPath, id);
        ls.Close();
    }
    if (err != KErrNone)
        return SendErr(aPath, err);
    TBuf<120> t(_L("Installing "));
    t.Append(TParsePtrC(aPath).NameAndExt().Left(100));
    SetLast(t);
    return SendOk(KNullDesC8);
}

static void PutLe32(TDes8 &aBuf, TUint32 aValue)
{
    for (TInt i = 0; i < 4; i++)
        aBuf.Append(TUint8(aValue >> (8 * i)));
}

struct TSmsRef
    {
    TMsvId iId;
    TInt iFolder;
    TInt64 iTime;
    static TInt Newer(const TSmsRef &aA, const TSmsRef &aB)
    {
        return aA.iTime > aB.iTime ? -1 : aA.iTime < aB.iTime ? 1 : 0;
    }
    };

TInt CLinkSession::SmsList(TInt aLimit)
{
    TQuietObserver obs;
    CMsvSession *session = NULL;
    CClientMtmRegistry *reg = NULL;
    CSmsClientMtm *mtm = NULL;
    TRAPD(err, session = CMsvSession::OpenSyncL(obs);
                reg = CClientMtmRegistry::NewL(*session);
                mtm = static_cast<CSmsClientMtm *>(reg->NewMtmL(KUidMsgTypeSMS)));
    if (err != KErrNone) {
        delete mtm;
        delete reg;
        delete session;
        return SendErr(_L("messages"), err);
    }
    static const struct {
        TMsvId iId;
        const TText8 *iName;
    } KFolders[] = {{KMsvGlobalInBoxIndexEntryId, _S8("in")},
                    {KMsvSentEntryId, _S8("sent")},
                    {KMsvGlobalOutBoxIndexEntryId, _S8("out")},
                    {KMsvDraftEntryId, _S8("draft")}};
    RBuf8 body;
    body.Create(16384);
    RArray<TSmsRef> refs;
    for (TUint f = 0; f < sizeof KFolders / sizeof KFolders[0]; f++) {
        CMsvEntry *folder = NULL;
        CMsvEntrySelection *sel = NULL;
        TRAP(err, folder = session->GetEntryL(KFolders[f].iId);
                  sel = folder->ChildrenWithMtmL(KUidMsgTypeSMS));
        delete folder;
        if (err != KErrNone || !sel)
            continue;
        for (TInt i = 0; i < sel->Count(); i++) {
            TMsvEntry e;
            TMsvId service;
            if (session->GetEntry(sel->At(i), service, e) == KErrNone) {
                TSmsRef r = {e.Id(), f, e.iDate.Int64()};
                refs.Append(r);
            }
        }
        delete sel;
    }
    refs.Sort(TLinearOrder<TSmsRef>(TSmsRef::Newer));
    for (TInt i = 0; i < refs.Count() && i < aLimit; i++) {
        TMsvEntry e;
        TMsvId service;
        TInt f = refs[i].iFolder;
        if (session->GetEntry(refs[i].iId, service, e) != KErrNone)
            continue;
        HBufC *text = NULL;
        TBuf<64> address;
        TRAP(err, mtm->SwitchCurrentEntryL(e.Id()); mtm->LoadMessageL();
                  CRichText &rich = mtm->Body();
                  text = HBufC::NewL(rich.DocumentLength());
                  TPtr tp = text->Des();
                  rich.Extract(tp, 0, rich.DocumentLength());
                  for (TInt k = 0; k < tp.Length(); k++)
                      if (tp[k] == CEditableText::EParagraphDelimiter || tp[k] == CEditableText::ELineBreak)
                          tp[k] = '\n';
                  if (KFolders[f].iId == KMsvGlobalInBoxIndexEntryId)
                      address = mtm->SmsHeader().FromAddress().Left(address.MaxLength());
                  else if (mtm->AddresseeList().Count())
                      address = mtm->AddresseeList()[0].Left(address.MaxLength()));
        body.AppendFormat(_L8("%d\t%s\t%Ld\t%d\t"), e.Id(), KFolders[f].iName, UnixTime(e.iDate),
                          e.Unread() ? 1 : 0);
        AppendEscaped(body, address.Length() ? TPtrC(address) : e.iDetails);
        body.Append('\t');
        AppendEscaped(body, e.iDetails);
        body.Append('\t');
        AppendEscaped(body, text ? TPtrC(*text) : e.iDescription);
        body.Append('\n');
        delete text;
    }
    refs.Close();
    delete mtm;
    delete reg;
    delete session;
    err = SendOk(body);
    body.Close();
    return err;
}

TInt CLinkSession::SmsSend(const TDesC &aTo, const TDesC8 &aText)
{
    RSendAs sendAs;
    TInt err = sendAs.Connect();
    if (err == KErrNone) {
        TRAP(err, HBufC *text = UnescapeLC(aText);
                  RSendAsMessage msg;
                  msg.CreateL(sendAs, KUidMsgTypeSMS);
                  CleanupClosePushL(msg);
                  msg.AddRecipientL(aTo, RSendAsMessage::ESendAsRecipientTo);
                  msg.SetBodyTextL(*text);
                  CleanupStack::Pop(&msg);
                  msg.SendMessageAndCloseL();
                  CleanupStack::PopAndDestroy(text));
        sendAs.Close();
    }
    if (err != KErrNone)
        return SendErr(_L("send"), err);
    TBuf<120> t(_L("Sent a text to "));
    t.Append(aTo.Left(60));
    SetLast(t);
    return SendOk(KNullDesC8);
}

TInt CLinkSession::SmsChange(const TDesC8 &aId, TBool aDelete)
{
    TLex8 lex(aId);
    TInt id;
    if (lex.Val(id) != KErrNone)
        return SendErr(_L("message id"), KErrArgument);
    TQuietObserver obs;
    CMsvSession *session = NULL;
    TRAPD(err, session = CMsvSession::OpenSyncL(obs);
               CMsvEntry *entry = session->GetEntryL(id);
               CleanupStack::PushL(entry);
               if (aDelete) {
                   CMsvEntry *parent = session->GetEntryL(entry->Entry().Parent());
                   CleanupStack::PushL(parent);
                   parent->DeleteL(id);
                   CleanupStack::PopAndDestroy(parent);
               } else {
                   TMsvEntry e = entry->Entry();
                   e.SetUnread(EFalse);
                   e.SetNew(EFalse);
                   entry->ChangeL(e);
               }
               CleanupStack::PopAndDestroy(entry));
    delete session;
    return err == KErrNone ? SendOk(KNullDesC8) : SendErr(_L("message"), err);
}

TInt CLinkSession::Shot()
{
    RWsSession ws;
    TInt err = ws.Connect();
    if (err != KErrNone)
        return SendErr(_L("window server"), err);
    CWsScreenDevice *dev = new CWsScreenDevice(ws);
    CFbsBitmap *bmp = new CFbsBitmap;
    if (!dev || !bmp)
        err = KErrNoMemory;
    if (err == KErrNone)
        err = dev->Construct();
    TSize size;
    if (err == KErrNone) {
        size = dev->SizeInPixels();
        err = bmp->Create(size, dev->DisplayMode());
    }
    if (err == KErrNone)
        err = dev->CopyScreenToBitmap(bmp);
    RBuf8 body;
    if (err == KErrNone) {
        TInt stride = (size.iWidth * 3 + 3) & ~3, image = stride * size.iHeight;
        err = body.Create(54 + image);
        if (err == KErrNone) {
            body.Append(_L8("BM"));
            PutLe32(body, 54 + image);
            PutLe32(body, 0);
            PutLe32(body, 54);
            PutLe32(body, 40);
            PutLe32(body, size.iWidth);
            PutLe32(body, size.iHeight);
            PutLe32(body, 1 | (24 << 16));
            PutLe32(body, 0);
            PutLe32(body, image);
            PutLe32(body, 2835);
            PutLe32(body, 2835);
            PutLe32(body, 0);
            PutLe32(body, 0);
            for (TInt y = size.iHeight - 1; y >= 0; y--) {
                TPtr8 row((TUint8 *)body.Ptr() + body.Length(), 0, stride);
                bmp->GetScanLine(row, TPoint(0, y), size.iWidth, EColor16M);
                body.SetLength(body.Length() + stride);
            }
        }
    }
    delete bmp;
    delete dev;
    ws.Close();
    if (err != KErrNone) {
        body.Close();
        return SendErr(_L("screenshot"), err);
    }
    err = SendOk(body);
    body.Close();
    SetLast(_L("Sent a screenshot"));
    return err;
}

TInt CLinkSession::Dispatch(const TDesC8 &aLine)
{
    TPtrC8 args[4];
    TInt n = 0;
    TPtrC8 rest(aLine);
    while (n < 4) {
        TInt tab = rest.Locate('\t');
        args[n++].Set(tab < 0 ? rest : rest.Left(tab));
        if (tab < 0)
            break;
        rest.Set(rest.Mid(tab + 1));
    }
    TPtrC8 cmd = args[0];
    TFileName a1, a2;
    if (n > 1)
        Utf8ToPath(args[1], a1);
    if (n > 2)
        Utf8ToPath(args[2], a2);
    if (cmd == _L8("HELLO"))
        return Hello();
    if (cmd == _L8("PING"))
        return SendOk(KNullDesC8);
    if (cmd == _L8("DRIVES"))
        return Drives();
    if (cmd == _L8("LS") && n > 1)
        return List(a1);
    if (cmd == _L8("GET") && n > 1)
        return Get(a1);
    if (cmd == _L8("PUT") && n > 2) {
        TLex8 lex(args[2]);
        TInt size;
        if (lex.Val(size) != KErrNone || size < 0)
            return KErrAbort;
        return Put(a1, size);
    }
    if (cmd == _L8("MKDIR") && n > 1) {
        if (a1.Length() && a1[a1.Length() - 1] != '\\')
            a1.Append('\\');
        TInt err = iFs.MkDirAll(a1);
        return err == KErrNone || err == KErrAlreadyExists ? SendOk(KNullDesC8) : SendErr(a1, err);
    }
    if (cmd == _L8("DEL") && n > 1) {
        TEntry e;
        TInt err = iFs.Entry(a1, e);
        if (err == KErrNone && e.IsDir()) {
            if (a1[a1.Length() - 1] != '\\')
                a1.Append('\\');
            CFileMan *fm = NULL;
            TRAP(err, fm = CFileMan::NewL(iFs));
            if (err == KErrNone)
                err = fm->RmDir(a1);
            delete fm;
        } else if (err == KErrNone) {
            iFs.SetAtt(a1, 0, KEntryAttReadOnly);
            err = iFs.Delete(a1);
        }
        return err == KErrNone ? SendOk(KNullDesC8) : SendErr(a1, err);
    }
    if (cmd == _L8("REN") && n > 2) {
        TInt err = iFs.Rename(a1, a2);
        return err == KErrNone ? SendOk(KNullDesC8) : SendErr(a1, err);
    }
    if (cmd == _L8("INSTALL") && n > 1)
        return Install(a1);
    if (cmd == _L8("SMSLIST")) {
        TInt limit = 300;
        if (n > 1) {
            TLex8 lex(args[1]);
            lex.Val(limit);
        }
        return SmsList(Max(limit, 1));
    }
    if (cmd == _L8("SMSSEND") && n > 2)
        return SmsSend(a1, args[2]);
    if (cmd == _L8("SMSREAD") && n > 1)
        return SmsChange(args[1], EFalse);
    if (cmd == _L8("SMSDEL") && n > 1)
        return SmsChange(args[1], ETrue);
    if (cmd == _L8("SHOT"))
        return Shot();
    return SendErr(_L("unknown command"), KErrNotSupported);
}

void CLinkSession::RunL()
{
    TBuf8<1024> line;
    while (!gStop && ReadLine(line) == KErrNone)
        if (Dispatch(line) != KErrNone)
            break;
}

static TBool LocalAddress(RSocketServ &aServ, RConnection &aConn, TDes &aOut)
{
    RSocket sock;
    if (sock.Open(aServ, KAfInet, KSockDatagram, KProtocolInetUdp, aConn) != KErrNone)
        return EFalse;
    TBool found = EFalse;
    if (sock.SetOpt(KSoInetEnumInterfaces, KSolInetIfCtrl) == KErrNone) {
        TPckgBuf<TSoInetInterfaceInfo> info;
        while (!found && sock.GetOpt(KSoInetNextInterface, KSolInetIfCtrl, info) == KErrNone) {
            TInetAddr a = info().iAddress;
            if (info().iState != EIfUp || (a.Family() == KAfInet6 && !a.IsV4Mapped()))
                continue;
            TUint32 v4 = a.Address();
            if (!v4 || (v4 >> 24) == 127)
                continue;
            TInetAddr out(v4, KPort);
            out.Output(aOut);
            found = ETrue;
        }
    }
    sock.Close();
    return found;
}

static void ServeL()
{
    RFs fs;
    User::LeaveIfError(fs.Connect());
    CleanupClosePushL(fs);
    User::LeaveIfError(RFbsSession::Connect());
    RSocketServ serv;
    User::LeaveIfError(serv.Connect());
    CleanupClosePushL(serv);
    RConnection conn;
    User::LeaveIfError(conn.Open(serv));
    CleanupClosePushL(conn);
    SetState(EStateStarting, _L("Choose your Wi-Fi network"));
    User::LeaveIfError(conn.Start());
    RSocket listener;
    User::LeaveIfError(listener.Open(serv, KAfInet, KSockStream, KProtocolInetTcp, conn));
    CleanupClosePushL(listener);
    listener.SetOpt(KSoReuseAddr, KSolInetIp, 1);
    TInetAddr any(KInetAddrAny, KPort);
    User::LeaveIfError(listener.Bind(any));
    User::LeaveIfError(listener.Listen(1));
    TBuf<40> addr;
    if (!LocalAddress(serv, conn, addr))
        addr = _L("unknown");
    gLock.Wait();
    gStatus.iAddress = addr;
    gStatus.iAddress.AppendFormat(_L(":%d"), KPort);
    gLock.Signal();
    SetState(EStateListening, _L("Waiting for the Mac"));
    RSocket sockets[2];
    TInt next = 0;
    TRequestStatus st;
    User::LeaveIfError(sockets[next].Open(serv));
    listener.Accept(sockets[next], st);
    while (!gStop) {
        User::WaitForRequest(st);
        if (st.Int() != KErrNone) {
            sockets[next].Close();
            User::Leave(st.Int());
        }
        RSocket &client = sockets[next];
        next ^= 1;
        User::LeaveIfError(sockets[next].Open(serv));
        listener.Accept(sockets[next], st);
        TInetAddr peer;
        client.RemoteName(peer);
        TBuf<40> who;
        peer.Output(who);
        gLock.Wait();
        gStatus.iClient = who;
        gLock.Signal();
        SetState(EStateClient, _L("Mac connected"));
        CLinkSession *s = new CLinkSession(client, fs, st);
        if (s) {
            TRAPD(err, s->ConstructL(); s->RunL());
            delete s;
        }
        client.Close();
        SetState(EStateListening, _L("Mac disconnected"));
    }
    CleanupStack::PopAndDestroy(4);
    RFbsSession::Disconnect();
}

static TInt ServerThread(TAny *)
{
    CTrapCleanup *cleanup = CTrapCleanup::New();
    CActiveScheduler *scheduler = new CActiveScheduler;
    if (scheduler)
        CActiveScheduler::Install(scheduler);
    TRAPD(err, ServeL());
    if (err != KErrNone) {
        TBuf<60> t;
        t.Format(_L("Wi-Fi link stopped (%d)"), err);
        SetState(EStateFailed, t);
    }
    delete scheduler;
    delete cleanup;
    return err;
}


class CStatusView : public CCoeControl
{
public:
    void ConstructL(const TRect &aRect)
    {
        CreateWindowL();
        iBg = CAknsBasicBackgroundControlContext::NewL(KAknsIIDQsnBgAreaMain, aRect, ETrue);
        SetRect(aRect);
        ActivateL();
    }
    ~CStatusView() { delete iBg; }

private:
    void SizeChanged()
    {
        if (iBg) {
            iBg->SetRect(Rect());
            iBg->SetParentPos(PositionRelativeToScreen());
        }
    }
    TTypeUid::Ptr MopSupplyObject(TTypeUid aId)
    {
        if (iBg && aId.iUid == MAknsControlContext::ETypeId)
            return MAknsControlContext::SupplyMopObject(aId, iBg);
        return CCoeControl::MopSupplyObject(aId);
    }
    void Draw(const TRect &) const
    {
        CWindowGc &gc = SystemGc();
        MAknsSkinInstance *skin = AknsUtils::SkinInstance();
        if (!AknsDrawUtils::Background(skin, iBg, this, gc, Rect())) {
            gc.SetBrushColor(KRgbWhite);
            gc.Clear(Rect());
        }
        TRgb color = KRgbBlack;
        AknsUtils::GetCachedColor(skin, color, KAknsIIDQsnTextColors, EAknsCIQsnTextColorsCG6);
        gc.SetPenColor(color);
        TLinkStatus s;
        gLock.Wait();
        s = gStatus;
        gLock.Signal();
        const CFont *big = AknLayoutUtils::FontFromId(EAknLogicalFontPrimaryFont);
        const CFont *small = AknLayoutUtils::FontFromId(EAknLogicalFontSecondaryFont);
        TInt x = 12, y = 14;
        gc.UseFont(big);
        static const TText *const KStates[] = {_S("Starting Wi-Fi..."), _S("Ready"),
                                               _S("Connected"), _S("Stopped")};
        y += big->AscentInPixels();
        gc.DrawText(TPtrC(KStates[s.iState]), TPoint(x, y));
        y += big->HeightInPixels() + 10;
        gc.DiscardFont();
        gc.UseFont(small);
        TInt lh = small->HeightInPixels() + 6;
        if (s.iAddress.Length()) {
            gc.DrawText(_L("On the Mac, connect to:"), TPoint(x, y += small->AscentInPixels()));
            gc.DiscardFont();
            gc.UseFont(big);
            y += big->HeightInPixels() + 4;
            gc.DrawText(s.iAddress, TPoint(x, y));
            gc.DiscardFont();
            gc.UseFont(small);
            y += lh;
        }
        if (s.iClient.Length()) {
            TBuf<60> t(_L("Mac: "));
            t.Append(s.iClient);
            gc.DrawText(t, TPoint(x, y += lh));
        }
        if (s.iLast.Length())
            gc.DrawText(s.iLast, TPoint(x, y += lh));
        gc.DiscardFont();
    }

    CAknsBasicBackgroundControlContext *iBg;
};

class CLinkAppUi : public CAknAppUi
{
public:
    void ConstructL()
    {
        BaseConstructL(EAknEnableSkin);
        User::LeaveIfError(gLock.CreateLocal());
        iView = new (ELeave) CStatusView;
        iView->SetMopParent(this);
        iView->ConstructL(ClientRect());
        AddToStackL(iView);
        Cba()->SetCommandL(EAknSoftkeyExit, _L("Hide"));
        iTimer = CPeriodic::NewL(CActive::EPriorityLow);
        iTimer->Start(1000000, 1000000, TCallBack(Tick, this));
        StartServer();
    }
    ~CLinkAppUi()
    {
        delete iTimer;
        StopServer();
        if (iView) {
            RemoveFromStack(iView);
            delete iView;
        }
        gLock.Close();
    }

private:
    void StartServer()
    {
        gStop = EFalse;
        gLock.Wait();
        gStatus.iAddress.Zero();
        gLock.Signal();
        SetState(EStateStarting, KNullDesC);
        TBuf<32> name;
        name.Format(_L("s60link%d"), ++iGeneration);
        if (iThread.Create(name, ServerThread, 0x8000, NULL, NULL) == KErrNone) {
            iRunning = ETrue;
            iThread.Resume();
        } else {
            SetState(EStateFailed, _L("Could not start"));
        }
    }
    void StopServer()
    {
        if (!iRunning)
            return;
        gStop = ETrue;
        iThread.Kill(KErrCancel);
        iThread.Close();
        iRunning = EFalse;
        gLock.Close();
        gLock.CreateLocal();
    }
    static TInt Tick(TAny *aSelf)
    {
        static_cast<CLinkAppUi *>(aSelf)->iView->DrawDeferred();
        return 0;
    }
    void HandleCommandL(TInt aCommand)
    {
        switch (aCommand) {
        case EAknSoftkeyExit: {
            TApaTask task(iEikonEnv->WsSession());
            task.SetWgId(iEikonEnv->RootWin().Identifier());
            task.SendToBackground();
            break;
        }
        case ELinkCmdRestart:
            StopServer();
            StartServer();
            break;
        case ELinkCmdExit:
        case EEikCmdExit:
            Exit();
            break;
        }
    }
    void HandleResourceChangeL(TInt aType)
    {
        CAknAppUi::HandleResourceChangeL(aType);
        if (aType == KEikDynamicLayoutVariantSwitch && iView)
            iView->SetRect(ClientRect());
    }

    CStatusView *iView;
    CPeriodic *iTimer;
    RThread iThread;
    TBool iRunning;
    TInt iGeneration;
};

class CLinkDocument : public CAknDocument
{
public:
    CLinkDocument(CEikApplication &aApp) : CAknDocument(aApp) {}
    CEikAppUi *CreateAppUiL() { return new (ELeave) CLinkAppUi; }
};

class CLinkApplication : public CAknApplication
{
    CApaDocument *CreateDocumentL() { return new (ELeave) CLinkDocument(*this); }
    TUid AppDllUid() const { return KUidS60Link; }
};

static CApaApplication *NewApplication() { return new CLinkApplication; }

GLDEF_C TInt E32Main() { return EikStart::RunApplication(NewApplication); }
