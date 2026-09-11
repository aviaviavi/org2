import AppKit
import SwiftUI
import WebKit

/// One DOM and one native WebKit scroll view own the entire visible transcript.
/// Selection, autoscroll while dragging, and wheel routing are WebKit behavior.
struct AIChatTranscriptDocument: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.openOrgFileReference) private var openFileReference
  @Environment(\.orgRoamLinkResolver) private var linkResolver
  @State private var rendered: [UUID: RenderedBody] = [:]
  @State private var inspectedMessage: OpenClawChatMessage?
  @State private var showsActivity = false
  let items: [AIChatRoomTranscriptItem]
  let compact: Bool
  let earlierTitle: String?
  let searchMessageID: UUID?
  let searchGeneration: Int
  let onEarlier: () -> Void
  let onPosition: (Double) -> Void

  private struct RenderedBody { let source: String; let html: String }
  private struct RenderInput: Equatable { let id: UUID; let text: String; let formatted: Bool }
  private struct RenderKey: Equatable { let sourcePath: String; let inputs: [RenderInput] }
  private var messages: [OpenClawChatMessage] {
    items.flatMap { item in
      switch item {
      case .message(let message): return [message]
      case .round(let round):
        return [round.trigger] + round.expectedDestinationIDs.compactMap { destination in
          round.response(forDestinationID: destination) ?? round.dispatch(forDestinationID: destination)
        }
      }
    }
  }
  private var sourcePath: String {
    (store.corpusRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent("chat-message.org").path
  }

  var body: some View {
    let inputs = messages.map { message in
      RenderInput(id: message.id,
        text: message.content,
        formatted: message.role == .assistant)
    }
    let entries = zip(messages, inputs).map { message, input in
      AIChatTranscriptHTML.Entry(
        id: message.id.uuidString.lowercased(), role: message.role.rawValue,
        title: title(message), timestamp: AIChatMessageTimestampPresentation.displayText(for: message.createdAt),
        html: rendered[message.id].flatMap { $0.source == input.text ? $0.html : nil } ?? AIChatDocumentHTML.plain(message.role == .user ? "Preparing message…" : input.text),
        attachments: message.attachments.map(\.fileName),
        failure: message.sendFailure,
        queued: store.isAIChatMessageQueued(message.id),
        canSteer: store.canSteerQueuedAIChatMessage(message.id),
        hasDetails: message.role == .user || message.responseTrace?.isEmpty == false || message.changeSummary != nil || !message.attachments.isEmpty,
        activityCount: message.responseTrace?.activities.count ?? 0
      )
    }
    AIChatTranscriptWebView(
      payload: AIChatTranscriptHTML.Payload(
        thread: store.selectedOpenClawChatThreadID?.uuidString ?? "empty",
        entries: entries, earlier: earlierTitle,
        sending: store.isSendingOpenClawMessage,
        status: store.openClawMessages.isEmpty ? "Ask about your workspace, or request an edit to review." : store.openClawStatusText,
        search: searchMessageID?.uuidString.lowercased(), searchGeneration: searchGeneration,
        initialPosition: store.openClawChatScrollPosition(isAssistantPanel: compact) ?? 1,
        compact: compact
      ), sourcePath: sourcePath, corpusRoot: store.corpusRoot,
      linkResolver: linkResolver, openFileReference: openFileReference,
      onAction: handleAction,
      onPosition: { thread, position in
        guard thread == store.selectedOpenClawChatThreadID?.uuidString else { return }
        store.recordOpenClawChatScrollPosition(position, isAssistantPanel: compact, threadID: store.selectedOpenClawChatThreadID)
        onPosition(position)
      }
    )
    .task(id: RenderKey(sourcePath: sourcePath, inputs: inputs)) {
      let ids = Set(inputs.map(\.id))
      rendered = rendered.filter { ids.contains($0.key) }
      for input in inputs where rendered[input.id]?.source != input.text {
        do {
          try Task.checkCancellation()
          let source = await Task.detached(priority: .userInitiated) {
            input.formatted ? OpenClawMessageOrgNormalizer.normalized(input.text)
              : OpenClawContextPresentation(input.text).userText
          }.value
          let html = input.formatted
            ? try await AIChatDocumentRenderCache.shared.render(source, sourcePath: sourcePath)
            : AIChatDocumentHTML.plain(source)
          try Task.checkCancellation()
          rendered[input.id] = RenderedBody(source: input.text, html: html)
        } catch is CancellationError { return }
        catch { /* The selectable plain body remains available. */ }
      }
    }
    .sheet(item: $inspectedMessage) { message in
      ScrollView {
        ChatBubbleView(message: message, runtime: store.selectedAIChatRuntime,
          destinationTitlesByID: store.aiChatDestinationTitlesByID, compact: false)
          .padding(16)
      }
      .frame(minWidth: 580, idealWidth: 720, minHeight: 400, idealHeight: 650)
    }
    .sheet(isPresented: $showsActivity) {
      ScrollView {
        OpenClawLiveTypingIndicatorView(
          liveState: store.openClawLiveState, threadID: store.selectedOpenClawChatThreadID,
          startedAt: store.openClawRequestStartedAt, runtime: store.selectedAIChatActiveRuntime,
          destinationTitle: store.aiChatDestinationTitle(store.selectedAIChatActiveDestinationID),
          compact: false, onStop: { Task { await store.stopOpenClawRun() } }
        ).padding(16)
      }.frame(minWidth: 580, minHeight: 400)
    }
  }

  private func title(_ message: OpenClawChatMessage) -> String {
    if message.role == .user {
      if !message.audienceDestinationIDs.isEmpty {
        return "You → " + message.audienceDestinationIDs.map(store.aiChatDestinationTitle).joined(separator: " + ")
      }
      return message.audience.map { "You → " + $0.title } ?? "You"
    }
    return message.authorLabel ?? message.authorDestinationID.map(store.aiChatDestinationTitle)
      ?? message.authorRuntime?.title ?? (message.role == .system ? "Org2" : store.selectedAIChatRuntime.title)
  }

  private func handleAction(_ action: String, _ id: String?) {
    if action == "restored" { store.completeOpenClawChatScrollRestoration(threadID: store.selectedOpenClawChatThreadID); return }
    if action == "earlier" { onEarlier(); return }
    if action == "stop" { Task { await store.stopOpenClawRun() }; return }
    if action == "activity" { showsActivity = true; return }
    guard let id, let uuid = UUID(uuidString: id), let message = messages.first(where: { $0.id == uuid }) else { return }
    switch action {
    case "copy": OpenClawMessageClipboard.write(message.content)
    case "details": inspectedMessage = message
    case "edit": store.editQueuedAIChatMessage(uuid)
    case "delete": store.deleteQueuedAIChatMessage(uuid)
    case "steer": Task { await store.steerQueuedAIChatMessage(uuid) }
    default: break
    }
  }
}

enum AIChatTranscriptHTML {
  struct Entry: Codable, Equatable {
    let id: String
    let role: String
    let title: String
    let timestamp: String
    let html: String
    let attachments: [String]
    let failure: String?
    let queued: Bool
    let canSteer: Bool
    let hasDetails: Bool
    let activityCount: Int
  }
  struct Payload: Codable, Equatable {
    let thread: String
    let entries: [Entry]
    let earlier: String?
    let sending: Bool
    let status: String
    let search: String?
    let searchGeneration: Int
    var initialPosition: Double
    let compact: Bool
  }

  static let style = AIChatDocumentHTML.style + """
  [hidden] { display:none!important; }
  html { overflow-y:auto; overflow-x:hidden; }
  body { padding:16px!important; }
  #messages { display:flex; flex-direction:column; gap:12px; }
  article { min-width:0; padding:11px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:9px; background:light-dark(#fcfbf8,#242624); margin-right:36px; }
  article.user { margin-right:0; margin-left:36px; background:light-dark(#eef2f9,#252d39); }
  article.match { outline:2px solid #609ce8; }
  .message-header { display:flex; align-items:center; gap:8px; font-size:11px; color:light-dark(#777,#aaa); margin-bottom:8px; }
  .message-header strong { color:inherit; }
  .message-header time { opacity:.7; }
  button { font:inherit; color:inherit; border:0; border-radius:4px; padding:3px 6px; background:transparent; cursor:pointer; user-select:none; -webkit-user-select:none; }
  button:hover { background:light-dark(#e5e5e5,#424242); }
  .message-actions { display:flex; gap:8px; font-size:12px; color:light-dark(#777,#aaa); }
  .message-actions:not(:empty) { margin-top:10px; }
  .failure { color:light-dark(#b33820,#ffa98d); white-space:pre-wrap; }
  #earlier { display:block; margin:0 auto 12px; }
  #status { padding:16px 0; color:light-dark(#777,#aaa); }
  #latest { position:fixed; bottom:12px; right:14px; border:1px solid #8886; border-radius:20px; background:light-dark(#fff,#333); box-shadow:0 2px 6px #0002; }
  pre { max-height:none!important; height:auto!important; overflow-x:auto; overflow-y:hidden; white-space:pre; }
  table { max-width:100%; table-layout:fixed; }
  """

  static let script = #"""
  (() => {
    let current = null, pending = null, nearBottom = true, searchToken = '';
    const post = (action, id) => webkit.messageHandlers.transcript.postMessage({action, id:id??null, thread:current?.thread??""});
    const selected = () => { const s=getSelection(); return s && !s.isCollapsed; };
    const maxScroll = () => Math.max(0,document.documentElement.scrollHeight-innerHeight);
    const report = () => {
      const max=maxScroll(); nearBottom=max-scrollY<60;
      document.getElementById('latest').hidden=nearBottom;
      webkit.messageHandlers.transcript.postMessage({position:max>0?scrollY/max:1,thread:current?.thread});
    };
    const button = (label, action, id) => {
      const b=document.createElement('button'); b.textContent=label;
      b.addEventListener('click',()=>post(action,id)); return b;
    };
    const makeMessage = e => {
      const a=document.createElement('article'); a.id='message-'+e.id; a.className=e.role;
      a.setAttribute('aria-label',e.title+' message');
      const header=document.createElement('header'); header.className='message-header';
      const title=document.createElement('strong'); title.textContent=e.title;
      const time=document.createElement('time'); time.textContent=e.timestamp;
      header.append(title,time,button('Copy','copy',e.id));
      if(e.queued) { const q=document.createElement('span'); q.textContent='Queued'; header.append(q); }
      a.append(header);
      const doc=new DOMParser().parseFromString(e.html,'text/html');
      const css=doc.querySelector('style');
      if(css && !document.getElementById('renderer-style')) { css.id='renderer-style'; document.head.prepend(css); }
      doc.querySelectorAll('script,.org2-document-header').forEach(x=>x.remove());
      const main=doc.querySelector('main') || doc.body;
      const body=document.createElement('main'); body.className='org2-document'; body.append(...main.childNodes);
      for(const pre of body.querySelectorAll('pre')) {
        const wrap=document.createElement('div'); wrap.className='chat-code'; pre.replaceWith(wrap); wrap.append(pre);
        const b=document.createElement('button'); b.className='chat-copy-code'; b.textContent='Copy code';
        b.onclick=()=>webkit.messageHandlers.chatCopyCode.postMessage(pre.textContent.replace(/\n$/,'')); wrap.append(b);
      }
      a.append(body);
      if(e.failure) { const f=document.createElement('p'); f.className='failure'; f.textContent=e.failure; a.append(f); }
      const actions=document.createElement('div'); actions.className='message-actions';
      for(const name of e.attachments) actions.append(button(name,'details',e.id));
      if(e.hasDetails) actions.append(button(e.activityCount ? 'How it worked · '+e.activityCount+' actions' : 'Message details','details',e.id));
      if(e.queued) { if(e.canSteer) actions.append(button('Steer now','steer',e.id)); actions.append(button('Edit','edit',e.id),button('Remove','delete',e.id)); }
      a.append(actions); a.dataset.entry=JSON.stringify(e); return a;
    };
    window.__transcriptUpdate = data => {
      const changedThread=current?.thread!==data.thread;
      if(!changedThread && selected()) { pending=data; return; }
      if(changedThread) getSelection().removeAllRanges();
      const oldTop=scrollY, first=[...document.querySelectorAll('article')].find(x=>x.getBoundingClientRect().bottom>0);
      const anchor=first?{id:first.id,top:first.getBoundingClientRect().top}:null;
      const follow=nearBottom && !selected();
      const root=document.getElementById('messages');
      if(changedThread) root.replaceChildren();
      const wanted=new Set(data.entries.map(e=>'message-'+e.id));
      for(const child of [...root.children]) if(!wanted.has(child.id)) child.remove();
      data.entries.forEach((e,i)=>{
        let a=document.getElementById('message-'+e.id);
        if(!a || a.dataset.entry!==JSON.stringify(e)) { const next=makeMessage(e); if(a) a.replaceWith(next); a=next; }
        if(root.children[i]!==a) root.insertBefore(a,root.children[i]||null);
        a.classList.toggle('match',data.search===e.id);
      });
      const earlier=document.getElementById('earlier'); earlier.textContent=data.earlier||''; earlier.hidden=!data.earlier;
      const status=document.getElementById('status'); status.replaceChildren();
      if(data.sending) { status.append(document.createTextNode('Working… '),button('View activity','activity'),button('Stop','stop')); }
      else if(!data.entries.length) status.textContent=data.status;
      current=data; pending=null;
      requestAnimationFrame(()=>{
        const token=data.thread+':'+data.searchGeneration+':'+data.search;
        const target=data.search && document.getElementById('message-'+data.search);
        if(target && token!==searchToken) { target.scrollIntoView({block:'center'}); searchToken=token; }
        else if(changedThread) scrollTo(0,maxScroll()*data.initialPosition);
        else if(follow) scrollTo(0,maxScroll());
        else if(anchor && document.getElementById(anchor.id)) scrollTo(0,oldTop+document.getElementById(anchor.id).getBoundingClientRect().top-anchor.top);
        report();
      });
    };
    document.addEventListener('selectionchange',()=>{ if(!selected() && pending) window.__transcriptUpdate(pending); });
    document.getElementById('earlier').onclick=()=>post('earlier');
    document.getElementById('latest').onclick=()=>scrollTo(0,maxScroll());
    let scheduled=false;
    addEventListener('scroll',()=>{ if(!scheduled) { scheduled=true; requestAnimationFrame(()=>{scheduled=false; report();}); } },{passive:true});
    new ResizeObserver(()=>{ if(current && nearBottom && !selected()) scrollTo(0,maxScroll()); }).observe(document.getElementById('messages'));
  })();
  """#

  static let shell = """
  <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: org2-resource:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'"><style>\(style)</style></head><body><button id="earlier" hidden></button><div id="messages"></div><div id="status"></div><button id="latest" hidden aria-label="Jump to latest message">↓</button></body></html>
  """
}

struct AIChatTranscriptWebView: NSViewRepresentable {
  let payload: AIChatTranscriptHTML.Payload
  let sourcePath: String
  let corpusRoot: URL?
  let linkResolver: OrgRoamLinkResolver
  let openFileReference: (OpenClawFileReference) -> Void
  let onAction: (String, String?) -> Void
  let onPosition: (String, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config=WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
    for name in ["transcript", "chatCopyCode"] { config.userContentController.add(context.coordinator, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: AIChatTranscriptHTML.script + "\n" + OrgHTMLRichCopy.installationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    let view=WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate=context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("Chat transcript")
    view.setAccessibilityIdentifier(OpenClawChatAccessibilityIdentity.transcriptScrollBridge)
    view.loadHTMLString(AIChatTranscriptHTML.shell, baseURL: URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let c=context.coordinator
    c.onAction=onAction; c.onPosition=onPosition; c.openFileReference=openFileReference
    c.sourcePath=sourcePath; c.corpusRoot=corpusRoot; c.linkResolver=linkResolver
    c.resources.configure(source: EntrySource(file:sourcePath,startLine:1,endLineExclusive:1,text:"",isSubtree:false),corpusRoot:corpusRoot)
    var next = payload
    if let previous = c.payload, previous.thread == next.thread { next.initialPosition = previous.initialPosition }
    guard c.payload != next else { return }
    c.payload=next
    if c.loaded { c.update(view) }
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    AIChatDocumentWebView.dismantleNSView(view, coordinator: coordinator)
    view.configuration.userContentController.removeScriptMessageHandler(forName:"transcript")
  }
  final class Coordinator: AIChatDocumentWebView.Coordinator {
    var payload: AIChatTranscriptHTML.Payload?
    var restoredThread: String?
    var onAction: ((String,String?) -> Void)?
    var onPosition: ((String,Double) -> Void)?
    override func update(_ view: WKWebView) {
      guard let payload, let data=try? JSONEncoder().encode(payload) else { return }
      // Rewrite HTML fields before encoding: JSON escaping must remain intact.
      var object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
      object["entries"] = payload.entries.map { entry -> [String:Any] in
        var value=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(entry))) as? [String:Any] ?? [:]
        value["html"]=OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in:entry.html)
        return value
      }
      view.callAsyncJavaScript("window.__transcriptUpdate(data)",arguments:["data":object],in:nil,in:.page)
    }
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name=="transcript" else { super.userContentController(controller,didReceive:message); return }
      guard message.frameInfo.isMainFrame, let value=message.body as? [String:Any],
            let thread=value["thread"] as? String, thread==payload?.thread else { return }
      if let position=value["position"] as? Double, position.isFinite {
        if restoredThread != thread { restoredThread = thread; onAction?("restored", nil) }
        onPosition?(thread,min(1,max(0,position)))
      }
      if let action=value["action"] as? String { onAction?(action,value["id"] as? String) }
    }
  }
}
