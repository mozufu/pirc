// Mounts the app's own Message and Markdown components in a stand-in shell so a
// real browser can show what untrusted content does to the surrounding page.
import { mount, tick } from 'svelte';
import '/src/app.css';
import '/src/markdown.css';
import Message from '/src/lib/components/Message.svelte';
import Markdown from '/src/lib/components/Markdown.svelte';
import { preloadRenderers } from '/src/lib/markdown.ts';

const approvals = [];
document.querySelector('#approve').addEventListener('click', () => approvals.push(Date.now()));

let mounted = [];
const message = (role, content, id) => ({
  id,
  role,
  content,
  createdAt: new Date(0).toISOString(),
});

window.pirc = {
  approvals: () => approvals.length,
  async ready() {
    await preloadRenderers();
  },
  /** Render `markdown` as an assistant message between two ordinary ones. */
  renderMessage(markdown) {
    const timeline = document.querySelector('#timeline');
    timeline.replaceChildren();
    mounted = [];
    for (const [role, content, id] of [
      ['user', 'Please run the migration.', 'u1'],
      ['assistant', markdown, 'a1'],
      ['assistant', 'Neighbouring message after the one under test.', 'a2'],
    ]) {
      const target = document.createElement('div');
      target.dataset.messageId = id;
      timeline.append(target);
      mounted.push(mount(Message, { target, props: { message: message(role, content, id) } }));
    }
  },
  /** Render `markdown` as an expanded system entry (extension / notice style message). */
  async renderSystem(markdown) {
    const timeline = document.querySelector('#timeline');
    timeline.replaceChildren();
    const target = document.createElement('div');
    target.dataset.messageId = 's1';
    timeline.append(target);
    const system = {
      ...message('system', markdown, 's1'),
      systemKind: 'custom',
      label: 'Extension',
    };
    mounted.push(mount(Message, { target, props: { message: system } }));
    const next = document.createElement('div');
    next.dataset.messageId = 'a2';
    timeline.append(next);
    mounted.push(
      mount(Message, {
        target: next,
        props: {
          message: message('assistant', 'Neighbouring message after the one under test.', 'a2'),
        },
      }),
    );
    await tick();
    target.querySelector('.system-line').click();
    await tick();
  },
  /** Render `markdown` the way the Files panel previews a Markdown document. */
  renderDocument(markdown) {
    const target = document.querySelector('#doc');
    target.replaceChildren();
    mounted.push(mount(Markdown, { target, props: { source: markdown } }));
  },
};
