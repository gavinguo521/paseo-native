#!/usr/bin/env python3
"""生成固定的协议回放样本；全部为测试数据，不含真实会话或凭据。"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'AppTests' / 'Fixtures'

def make(name, items):
    events = [{'kind': 'page', 'payload': {'direction': 'tail', 'epoch': name, 'entries': [], 'startCursor': {'seq': 0}, 'endCursor': {'seq': 0}}}]
    history = []
    for seq, item in enumerate(items, 1):
        timestamp = '2026-01-01T00:00:00Z'
        events.append({'kind': 'stream', 't': seq * 20, 'payload': {'epoch': name, 'seq': seq, 'timestamp': timestamp, 'event': {'type': 'timeline', 'turnId': 'turn-1', 'item': item}}})
        if history and item['type'] in ('assistant_message', 'reasoning') and history[-1]['item']['type'] == item['type']:
            history[-1]['item']['text'] += item['text']
            history[-1]['seqEnd'] = seq
        else:
            history.append({'seqStart': seq, 'seqEnd': seq, 'timestamp': timestamp, 'turnId': 'turn-1', 'item': dict(item)})
    events.append({'kind': 'snapshot', 'payload': {'direction': 'tail', 'epoch': name, 'entries': history, 'startCursor': {'seq': 1}, 'endCursor': {'seq': len(items)}}})
    return ''.join(json.dumps(event, ensure_ascii=False, separators=(',', ':')) + '\n' for event in events)

def chunks(text, size=47):
    return [{'type': 'assistant_message', 'text': text[i:i+size]} for i in range(0, len(text), size)]

def tool(status, output, error=None):
    item = {'type': 'tool_call', 'callId': 'build', 'name': 'shell', 'status': status,
            'detail': {'type': 'shell', 'command': 'build --test', 'output': output, 'exitCode': 1 if error else 0}}
    if error: item['error'] = {'message': error}
    return item

def scenarios():
    user = {'type': 'user_message', 'messageId': 'prompt', 'text': '请检查项目并汇总结果。'}
    mixed = [user, {'type': 'reasoning', 'text': '先检查输入。'}, tool('running', 'Starting\n'), tool('running', 'Starting\nChecking\n'), tool('failed', '检查失败\n', '测试错误：缺少输入'), tool('completed', '修正后通过\nFINAL LOG MARKER')]
    mixed += chunks('## 检查完成\n\n工具输出已更新，没有重复卡片。\n\nFINAL REPLY MARKER')
    long_reply = [user] + chunks('## 长回复\n\n' + ''.join(f'第 {i} 段：固定样本，用来观察流式布局和阅读位置。\n\n' for i in range(80)) + 'FINAL REPLY MARKER')
    table_code = [user] + chunks('```swift\n' + '\n'.join(f'let value{i} = {i}' for i in range(40)) + '\n```\n\n| 项目 | 数量 |\n| --- | ---: |\n' + ''.join(f'| 行 {i} | {i} |\n' for i in range(35)) + '\nFINAL REPLY MARKER', 31)
    return {'mixed-tools': mixed, 'long-reply': long_reply, 'table-code': table_code}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for name, items in scenarios().items():
        path = ROOT / (name + '.jsonl')
        expected = make(name, items)
        if args.check:
            if not path.exists() or path.read_text() != expected: raise SystemExit('样本不一致：' + str(path))
        else:
            ROOT.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
    print('固定回放样本一致' if args.check else '已生成固定回放样本')
