import Foundation

extension BrowserWindowController {
    func refreshConversationNavigatorDiagnostics() {
        guard !isDisposing, Self.canInjectPromptContent(into: webView.url) else { return }
        webView.evaluateJavaScript("window.__chatgptSwiftConversationNavigator?.diagnose() ?? null") { [weak self] result, _ in
            guard let self, !self.isDisposing, let values = result as? [String: Any] else { return }
            self.conversationNavigatorDiagnostics = ["version", "count", "mounted", "indexed", "distinctPositions", "updates", "scans", "apiRequests", "apiResponses", "hasEarlier"]
                .compactMap { key -> String? in
                    guard let number = values[key] as? NSNumber else { return nil }
                    return "\(key)=\(number.intValue)"
                }.joined(separator: ", ")
            for key in ["apiShape", "apiType"] {
                if let value = values[key] as? String { self.conversationNavigatorDiagnostics += ", \(key)=\(value.prefix(1200))" }
            }
            if let paths = values["apiPaths"] as? [String] {
                self.conversationNavigatorDiagnostics += ", apiPaths=" + paths.prefix(10).joined(separator: "|")
            }
        }
    }

    /// A left-side question rail. Conversation text stays in the page's memory.
    static let conversationNavigatorScript = #"""
    (() => {
      const host = location.hostname.toLowerCase();
      if (window !== window.top || location.protocol !== 'https:' ||
          (location.port && location.port !== '443') ||
          !(host === 'chatgpt.com' || host.endsWith('.chatgpt.com') ||
            host === 'chat.openai.com' || host.endsWith('.chat.openai.com'))) return;
      if (window.__chatgptSwiftConversationNavigator) return;
      const blocked = () => location.pathname.startsWith('/cdn-cgi/') ||
        !!document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#cf-challenge-running,#challenge-stage,[data-cf-challenge]');
      const railID = 'chatgpt-swift-conversation-navigator';
      const messageSelector = '[data-message-author-role="user"],[class~="group/user-message"]';
      const replySelector = '[data-message-author-role="assistant"],.markdown';
      const excluded = 'button,svg,style,script,nav,form,textarea,input,[aria-hidden="true"],.sr-only,[class*="group-hover/user-message"]';
      const state = {path:location.pathname, entries:[], mounted:[], indexed:[], buttons:[], active:0,
        rail:null, list:null, preview:null, title:null, answer:null, main:null, root:null,
        timer:0, frame:0, observer:null, sizes:null, updates:0, scans:0, hover:-1, jump:0, disposed:false,
        apiRequests:0,apiResponses:0,apiShape:'',apiType:'',messageIndex:new Map(),hasEarlier:false,indexAbort:null};
      const clamp = (value,low,high) => Math.max(low,Math.min(value,high));
      const visible = node => {
        if (!node?.isConnected || node.closest('[hidden],[inert],[aria-hidden="true"]')) return false;
        const rect=node.getBoundingClientRect(), style=getComputedStyle(node);
        return rect.width>1 && rect.height>1 && style.display!=='none' && style.visibility!=='hidden';
      };
      const textOf = (node, limit=500) => {
        if (!node) return '';
        let text='';
        const walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT,{
          acceptNode:leaf => leaf.parentElement?.closest(excluded) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
        for(let leaf=walker.nextNode();leaf && text.length<limit;leaf=walker.nextNode()) text+=' '+leaf.nodeValue;
        return text.replace(/\s+/g,' ').trim().slice(0,limit);
      };
      const mainView = () => [...document.querySelectorAll('main,[role="main"]')].find(main =>
        visible(main) && main.querySelector(messageSelector)) || null;
      const scrollRoot = node => {
        for(let parent=node?.parentElement;parent && parent!==document.body;parent=parent.parentElement) {
          const style=getComputedStyle(parent);
          if (parent.clientHeight>0 && /(auto|scroll|overlay)/.test(style.overflowY) &&
              parent.scrollHeight>parent.clientHeight+4) return parent;
        }
        return document.scrollingElement;
      };
      const scan = () => {
        state.scans++;
        const main=mainView();
        if (!main) return {main:null,messages:[]};
        const nodes=[...main.querySelectorAll(messageSelector)].filter(node =>
          !node.parentElement?.closest(messageSelector) && visible(node));
        const roots=new Set(), messages=[];
        for(const node of nodes) {
          const turn=node.closest('article,[data-testid^="conversation-turn-"],[data-turn-id]') || node;
          if(roots.has(turn)) continue;
          roots.add(turn);
          const bubble=node.querySelector('.bg-user-message') || node;
          const question=textOf(bubble), attachments=!!node.querySelector('img,video,audio,canvas');
          if(!question && !attachments) continue;
          messages.push({node,question:question || '图片或附件问题',answer:''});
        }
        const replies=[...main.querySelectorAll(replySelector)].filter(node =>
          !node.closest(messageSelector) && visible(node));
        messages.forEach((entry,index) => {
          const next=messages[index+1]?.node;
          const reply=replies.find(node =>
            !!(entry.node.compareDocumentPosition(node)&Node.DOCUMENT_POSITION_FOLLOWING) &&
            (!next || !!(node.compareDocumentPosition(next)&Node.DOCUMENT_POSITION_FOLLOWING)));
          entry.answer=textOf(reply,640);
          if(!entry.answer) {
            const heading=[...main.querySelectorAll('h4.sr-only')].find(node =>
              (node.textContent || '').trim().startsWith('ChatGPT') &&
              !!(entry.node.compareDocumentPosition(node)&Node.DOCUMENT_POSITION_FOLLOWING) &&
              (!next || !!(node.compareDocumentPosition(next)&Node.DOCUMENT_POSITION_FOLLOWING)));
            if(heading) {
              const walker=document.createTreeWalker(main,NodeFilter.SHOW_TEXT,{
                acceptNode:leaf=>leaf.parentElement?.closest(excluded)?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT
              });
              walker.currentNode=heading;
              let text='';
              for(let leaf=walker.nextNode();leaf && text.length<640;leaf=walker.nextNode()) {
                if(next && (next.contains(leaf) || (next.compareDocumentPosition(leaf)&Node.DOCUMENT_POSITION_FOLLOWING))) break;
                text+=' '+leaf.nodeValue;
              }
              entry.answer=text.replace(/\s+/g,' ').trim().slice(0,640);
            }
          }
        });
        return {main,messages};
      };
      const hidePreview = () => {
        state.hover=-1;
        if(state.preview) state.preview.hidden=true;
      };
      const ensureChrome = () => {
        if(state.rail?.isConnected) return;
        document.getElementById(railID)?.remove();
        document.getElementById(railID+'-style')?.remove();
        const style=document.createElement('style');
        style.id=railID+'-style';
        style.textContent=`
          #${railID} { position:fixed; width:28px; z-index:1000; color:var(--text-primary,#202123); }
          #${railID}[hidden], #${railID} [hidden] { display:none !important; }
          #${railID}-list { display:flex; flex-direction:column; overflow-y:auto; scrollbar-width:none; }
          #${railID}-list::-webkit-scrollbar { display:none; }
          #${railID} .question-marker {
            display:flex; align-items:center; justify-content:flex-start; flex:none;
            width:28px; height:12px; min-height:0; box-sizing:border-box; margin:0; padding:0 6px; border:0; border-radius:0;
            background:transparent; cursor:pointer; box-shadow:none;
          }
          #${railID} .question-marker::before {
            content:""; height:2px; width:8px; background:var(--text-tertiary,#c9cacc);
            transition:width 100ms ease,background 100ms ease;
          }
          #${railID} .question-marker[aria-current="true"]::before { width:14px; background:var(--text-primary,#202123); }
          #${railID} .question-marker:hover::before, #${railID} .question-marker:focus-visible::before { width:20px; background:var(--text-primary,#202123); }
          #${railID} .question-marker:focus-visible { outline:1px solid var(--text-tertiary,#c9cacc); outline-offset:0; border-radius:3px; }
          #${railID}-preview {
            position:fixed; width:320px; max-width:calc(100vw - 64px); padding:10px 12px;
            border:1px solid var(--border-light,#dedede); border-radius:12px;
            background:var(--bg-primary,#fff); color:var(--text-primary,#202123);
            box-shadow:0 6px 20px rgba(0,0,0,.08); pointer-events:none; box-sizing:border-box;
            font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;
          }
          #${railID}-preview strong { display:-webkit-box; -webkit-box-orient:vertical; -webkit-line-clamp:2; overflow:hidden; font-weight:600; }
          #${railID}-preview p { display:-webkit-box; -webkit-box-orient:vertical; -webkit-line-clamp:3; overflow:hidden; margin:5px 0 0; color:var(--text-secondary,#8e8ea0); }
          @media(prefers-color-scheme:dark) {
            #${railID} { color:var(--text-primary,#ececec); }
            #${railID} .question-marker::before { background:var(--text-tertiary,#696969); }
            #${railID} .question-marker[aria-current="true"]::before, #${railID} .question-marker:hover::before { background:var(--text-primary,#ececec); }
            #${railID}-preview { background:var(--bg-primary,#212121); color:var(--text-primary,#ececec); border-color:var(--border-light,#444); }
          }
          @media(prefers-reduced-motion:reduce) { #${railID} .question-marker::before { transition:none; } }
        `;
        (document.head || document.documentElement).append(style);
        const rail=document.createElement('nav'); rail.id=railID; rail.setAttribute('aria-label','对话问题导航');
        const list=document.createElement('div'); list.id=railID+'-list';
        const preview=document.createElement('div'); preview.id=railID+'-preview'; preview.hidden=true;
        preview.setAttribute('role','tooltip');
        const title=document.createElement('strong'),answer=document.createElement('p');
        preview.append(title,answer); rail.append(list,preview); document.body.append(rail);
        Object.assign(state,{rail,list,preview,title,answer});
        rail.addEventListener('pointerleave',hidePreview);
        rail.addEventListener('focusout',event => { if(!rail.contains(event.relatedTarget)) hidePreview(); });
      };
      const showPreview = index => {
        const entry=state.entries[index],button=state.buttons[index];
        if(!entry || !button) return;
        state.hover=index;
        state.title.textContent=entry.question;
        state.answer.textContent=entry.answer || '点击跳转到这条问题';
        state.preview.hidden=false;
        const rect=button.getBoundingClientRect();
        state.preview.style.left=clamp(rect.right+12,8,innerWidth-state.preview.offsetWidth-8)+'px';
        state.preview.style.top=clamp(rect.top-12,8,innerHeight-state.preview.offsetHeight-8)+'px';
      };
      const layout = () => {
        state.frame=0;
        if(state.disposed || !state.main || !state.rail || blocked()) return;
        const rect=state.main.getBoundingClientRect();
        const rootRect=state.root===document.scrollingElement ? rect : state.root.getBoundingClientRect();
        const top=Math.max(64,rootRect.top+16);
        state.rail.style.left=Math.max(8,rect.left+10)+'px';
        state.rail.style.top=top+'px';
        const available=Math.max(60,Math.min(innerHeight-140,rootRect.bottom)-top-16);
        state.list.style.maxHeight=available+'px';
        const rowHeight=Math.max(4,Math.min(12,available/Math.max(1,state.entries.length)));
        state.buttons.forEach(button=>{button.style.height=rowHeight+'px';});
        let active=state.active;
        const anchor=rootRect.top+Math.min(160,rootRect.height*.28);
        state.entries.forEach((entry,index) => {
          if(entry.node?.isConnected && entry.node.getBoundingClientRect().top<=anchor) active=index;
        });
        state.active=active;
        state.buttons.forEach((button,index) => button.setAttribute('aria-current',String(index===active)));
        if(state.hover>=0) showPreview(state.hover);
      };
      const scheduleLayout = () => { if(!state.frame) state.frame=requestAnimationFrame(layout); };
      const bindMounted = messages => {
        if(!state.indexed.length) return messages;
        const entries=state.indexed.map(entry => ({...entry,node:null}));
        let cursor=entries.length-1,lastMatched=-1;
        const unmatched=[];
        for(let i=messages.length-1;i>=0;i--) {
          const message=messages[i];
          let index=-1;
          for(let j=cursor;j>=0;j--) if(entries[j].question===message.question ||
              (message.question.length>=120 && entries[j].question.startsWith(message.question))) {index=j;break;}
          if(index<0) {unmatched.push({message,position:i});continue;}
          lastMatched=Math.max(lastMatched,i);
          entries[index].node=message.node;
          if(message.answer) entries[index].answer=message.answer;
          cursor=index-1;
        }
        for(const {message,position} of unmatched.reverse()) if(position>lastMatched && lastMatched>=0) entries.push(message);
        return entries;
      };
      const jumpTo = async index => {
        const generation=++state.jump,path=state.path;
        hidePreview(); state.active=index; scheduleLayout();
        state.buttons.forEach((button,j) => button.setAttribute('aria-current',String(j===index)));
        for(let attempt=0;attempt<24;attempt++) {
          if(generation!==state.jump || state.disposed || location.pathname!==path || blocked()) return;
          const entry=state.entries[index]; if(!entry) return;
          if(entry.node?.isConnected) {
            entry.node.scrollIntoView({block:'start',inline:'nearest',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
            return;
          }
          const root=state.root;
          if(!root) return;
          const max=Math.max(0,root.scrollHeight-root.clientHeight);
          const mounted=state.entries.map((item,j)=>({item,index:j})).filter(({item})=>item.node?.isConnected);
          if(mounted.length && index<mounted[0].index) mounted[0].item.node.scrollIntoView({block:'start',behavior:'auto'});
          else if(mounted.length && index>mounted[mounted.length-1].index) mounted[mounted.length-1].item.node.scrollIntoView({block:'end',behavior:'auto'});
          else root.scrollTop=index===0 ? 0 : max*index/Math.max(1,state.entries.length-1);
          await new Promise(resolve => setTimeout(resolve,250));
          const result=scan(); state.entries=bindMounted(result.messages);
        }
        if(state.preview && state.entries[index]) {
          showPreview(index); state.answer.textContent='较早的消息尚未载入，请稍后再点一次';
        }
      };
      const resetRoute = () => {
        if(state.path===location.pathname) return;
        state.path=location.pathname; state.indexed=[]; state.entries=[]; state.mounted=[]; state.active=0; state.jump++;
        state.messageIndex.clear();state.hasEarlier=false;
        state.indexAbort?.abort();state.indexAbort=null;
        hidePreview();
      };
      const refresh = () => {
        state.timer=0;
        if(state.disposed) return;
        resetRoute();
        if(blocked()) {if(state.rail) state.rail.hidden=true;return;}
        const result=scan();
        if(!result.main || (!result.messages.length && !state.indexed.length)) {
          if(state.rail) state.rail.hidden=true;
          return;
        }
        state.main=result.main; state.root=scrollRoot(result.messages[0]?.node);
        state.mounted=result.messages;
        const entries=bindMounted(result.messages);
        const changed=entries.length!==state.entries.length || entries.some((entry,index) =>
          entry.question!==state.entries[index]?.question || entry.node!==state.entries[index]?.node);
        state.entries=entries;
        ensureChrome(); state.rail.hidden=false;
        state.sizes.disconnect(); state.sizes.observe(state.main);
        if(changed || state.buttons.length!==entries.length) {
          hidePreview(); state.list.replaceChildren(); state.buttons=[];
          entries.forEach((entry,index) => {
            const button=document.createElement('button'); button.type='button'; button.className='question-marker';
            button.dataset.index=String(index);
            button.setAttribute('aria-label',`问题 ${index+1}：${entry.question}`);
            button.setAttribute('aria-describedby',railID+'-preview');
            button.addEventListener('pointerenter',() => showPreview(index));
            button.addEventListener('focus',() => showPreview(index));
            button.addEventListener('click',() => jumpTo(index));
            state.list.append(button); state.buttons.push(button);
          });
          state.updates++;
        }
        cancelAnimationFrame(state.frame); layout();
      };
      const schedule = () => {if(state.sizes && !state.timer && !state.disposed) state.timer=setTimeout(refresh,120);};
      // Reuse the page's conversation request to read older pages of this same conversation.
      const conversationID = () => location.pathname.match(/\/c\/([a-zA-Z0-9-]+)/)?.[1] || '';
      const indexConversation = (payload,id,isOlderPage=false) => {
        if(id!==conversationID() || !payload || typeof payload!=='object') return;
        resetRoute();
        let messages=[];
        if(Array.isArray(payload.messages)) {
          if(!isOlderPage) state.messageIndex.clear();
          for(const message of payload.messages.slice(0,10000)) {
            if(!message || typeof message.id!=='string' || !['user','assistant'].includes(message.author?.role) ||
                message.metadata?.is_visually_hidden_from_conversation ||
                (message.author.role==='assistant' && message.channel && message.channel!=='final')) continue;
            const parts=message.content?.parts;
            const text=Array.isArray(parts)?parts.filter(part=>typeof part==='string').join(' ').replace(/\s+/g,' ').trim():'';
            state.messageIndex.set(message.id,{id:message.id,author:message.author,channel:message.channel,recipient:message.recipient,
              create_time:typeof message.create_time==='number'?message.create_time:0,content:{parts:[text.slice(0,640)]}});
          }
          messages=[...state.messageIndex.values()].sort((a,b)=>a.create_time-b.create_time);
          state.hasEarlier=payload.page_info?.has_previous_page===true;
        } else if(payload.mapping && typeof payload.mapping==='object' && typeof payload.current_node==='string') {
          const chain=[],seen=new Set(); let key=payload.current_node;
          while(key && !seen.has(key) && chain.length<10000) {
            seen.add(key); const node=payload.mapping[key]; if(!node || typeof node!=='object') break;
            chain.push(node); key=typeof node.parent==='string' ? node.parent : '';
          }
          messages=chain.reverse().map(node=>node.message);
        }
        const entries=[];
        const content = message => Array.isArray(message?.content?.parts) ?
          message.content.parts.filter(part=>typeof part==='string').join(' ').replace(/\s+/g,' ').trim() : '';
        for(const message of messages) {
          if(!message || message.metadata?.is_visually_hidden_from_conversation) continue;
          const role=message.author?.role;
          if(role==='user') entries.push({question:content(message).slice(0,500)||'图片或附件问题',answer:'',node:null});
          else if(role==='assistant' && (!message.channel || message.channel==='final') &&
              (!message.recipient || message.recipient==='all') && entries.length &&
              !entries[entries.length-1].answer && content(message)) entries[entries.length-1].answer=content(message).slice(0,640);
        }
        if(entries.length) {resetRoute();state.indexed=entries;schedule();}
      };
      const loadEarlier = async (payload,id,url,request,init) => {
        if(!Array.isArray(payload.messages) || payload.page_info?.has_previous_page!==true || state.indexAbort) return;
        const controller=new AbortController();state.indexAbort=controller;
        const seen=new Set();
        try {
          for(let page=0;page<100 && state.messageIndex.size<10000;page++) {
            if(state.disposed || blocked() || id!==conversationID() || controller.signal.aborted) return;
            const cursor=payload.page_info?.start_cursor;
            if(payload.page_info?.has_previous_page!==true || typeof cursor!=='string' || !cursor || cursor.length>4096 || seen.has(cursor)) break;
            seen.add(cursor);
            const nextURL=new URL(url.href);nextURL.searchParams.set('before',cursor);nextURL.searchParams.set('num_turns','100');
            const base=typeof request==='string'?nextURL.href:new Request(nextURL.href,request);
            const options={...init,method:'GET',signal:controller.signal};
            state.apiRequests++;
            const response=await Reflect.apply(originalFetch,window,[base,options]);
            if(!response.ok || !response.headers.get('content-type')?.includes('json') || Number(response.headers.get('content-length') || 0)>25*1024*1024) break;
            const text=await response.text();
            if(text.length>25*1024*1024 || id!==conversationID() || controller.signal.aborted) break;
            payload=JSON.parse(text);state.apiResponses++;
            indexConversation(payload,id,true);
          }
        } catch(_) {} finally {if(state.indexAbort===controller) state.indexAbort=null;}
      };
      const originalFetch=window.fetch;
      const navigatorFetch=function(...args) {
        const promise=Reflect.apply(originalFetch,this,args);
        try {
          const request=args[0],url=new URL(typeof request==='string'?request:request.url,location.href);
          const method=String(args[1]?.method || request?.method || 'GET').toUpperCase();
          const match=url.pathname.match(/^\/backend-api\/conversations?\/([a-zA-Z0-9-]+)$/);
          if(method==='GET' && url.origin===location.origin && match) {
            state.apiRequests++;
            promise.then(response => {
            state.apiType=String(response.headers.get('content-type') || '').slice(0,80);
            if(!response.ok || !response.headers.get('content-type')?.includes('json') ||
                Number(response.headers.get('content-length') || 0)>25*1024*1024) return;
            response.clone().text().then(text => {
              if(text.length<=25*1024*1024 && !state.disposed) {
                const payload=JSON.parse(text);state.apiResponses++;
                const shape=(value,depth=0)=>Array.isArray(value)?'['+value.length+':'+(depth<2?shape(value[0],depth+1):typeof value[0])+']':
                  value && typeof value==='object' && depth<2?'{'+Object.entries(value).slice(0,16).map(([key,item])=>key+':'+shape(item,depth+1)).join(',')+'}':typeof value;
                state.apiShape=['sectioned_conversation','messages','current_node','page_info'].map(key=>key+':'+shape(payload?.[key])).join(' ');
                state.apiShape=state.apiShape.replace(/[a-zA-Z0-9_-]{24,}/g,'<id>');
                indexConversation(payload,match[1],url.searchParams.has('before'));
                if(!url.searchParams.has('before')) loadEarlier(payload,match[1],url,request,args[1]);
              }
            }).catch(()=>{});
          }).catch(()=>{}); }
        } catch(_) {}
        return promise;
      };
      window.fetch=navigatorFetch;
      const dispose = () => {
        state.disposed=true;state.jump++;clearTimeout(state.timer);cancelAnimationFrame(state.frame);
        state.observer?.disconnect();state.sizes?.disconnect();
        state.rail?.remove();document.getElementById(railID+'-style')?.remove();
        document.removeEventListener('scroll',scheduleLayout,true);window.removeEventListener('resize',scheduleLayout);
        if(window.fetch===navigatorFetch) window.fetch=originalFetch;
        state.entries=[];state.indexed=[];state.mounted=[];state.buttons=[];
        state.messageIndex.clear();
        state.indexAbort?.abort();state.indexAbort=null;
      };
      window.__chatgptSwiftConversationNavigator={refresh:schedule,dispose,
        diagnose:()=>({version:2,count:state.entries.length,mounted:state.mounted.length,indexed:state.indexed.length,
          visible:!!state.rail && !state.rail.hidden,updates:state.updates,scans:state.scans,
          apiRequests:state.apiRequests,apiResponses:state.apiResponses,apiShape:state.apiShape,apiType:state.apiType,
          hasEarlier:state.hasEarlier,
          apiPaths:[...new Set(performance.getEntriesByType('resource').map(entry=>{
            try {return new URL(entry.name).pathname.replace(/\/[a-zA-Z0-9_-]{24,}(?=\/|$)/g,'/<id>');}catch(_){return '';}
          }).filter(path=>path.includes('conversation')))].slice(0,10),
          distinctPositions:new Set(state.buttons.map(button=>Math.round(button.getBoundingClientRect().top))).size})};
      const boot = () => {
        if(state.disposed || blocked()) return;
        state.sizes=new ResizeObserver(scheduleLayout);
        state.observer=new MutationObserver(mutations => {
          if(state.path!==location.pathname) {schedule();return;}
          for(const mutation of mutations) {
            if(mutation.target instanceof Element && mutation.target.closest('#'+railID)) continue;
            if(mutation.type==='attributes') {
              if(mutation.target.matches(messageSelector) || mutation.target===state.main) {schedule();return;}
              continue;
            }
            for(const node of [...mutation.addedNodes,...mutation.removedNodes]) {
              if(!(node instanceof Element) || node.id===railID || node.id===railID+'-style') continue;
              if(node.matches(messageSelector+' ,main') || node.querySelector(messageSelector) ||
                  state.mounted.some(entry=>node.contains(entry.node))) {schedule();return;}
            }
          }
        });
        state.observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['data-message-author-role','hidden']});
        document.addEventListener('scroll',scheduleLayout,{capture:true,passive:true});
        window.addEventListener('resize',scheduleLayout,{passive:true});
        document.addEventListener('wheel',()=>{state.jump++;},{capture:true,passive:true});
        document.addEventListener('keydown',event=>{if(event.key==='Escape') {hidePreview();state.jump++;}},true);
        schedule();
      };
      window.addEventListener('pagehide',dispose,{once:true});
      if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
    })()
    """#
}
