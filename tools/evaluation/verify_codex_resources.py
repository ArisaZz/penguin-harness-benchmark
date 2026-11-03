"""Validate the Codex Sec A-E resource backfill without the private run archive.

Usage: python3 tools/evaluation/verify_codex_resources.py [--base-ref COMMIT]
Requires PyYAML. Only the five Codex experiments are checked; the other harnesses
in the parent comparison PR may still contain incomplete measurements.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import json
from pathlib import Path
import re
import statistics
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[2]
FIELDS = ('time', 'score', 'cost', 'duration_ms', 'n_input_tokens', 'n_cache_tokens', 'n_output_tokens')
TOKEN_FIELDS = {'input':'n_input_tokens', 'cache_read':'n_cache_tokens', 'output':'n_output_tokens', 'total':'n_total_tokens'}


def read_json(path):
    return json.loads(path.read_text(), parse_float=Decimal)


def utc(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def to_seconds(value):
    return utc(value).astimezone(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def close(actual, expected, tolerance='0.000000000001'):
    assert abs(Decimal(str(actual))-Decimal(expected)) <= Decimal(tolerance), (actual, expected)


def price(tokens, rates):
    return (Decimal(tokens['input']-tokens['cache_read'])*rates['prompt_tokens']
            + Decimal(tokens['cache_read'])*rates['cached_tokens']
            + Decimal(tokens['output'])*rates['response_tokens'])/Decimal(1000000)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-ref', help='Also verify scores, repetition assignments and durations against this git revision.')
    args = parser.parse_args()
    ids = set(); response_ids = set(); counts = Counter(); group_results = []
    observed_total = Counter(); evaluation_total = Counter(); costs = Decimal(0)
    for letter in 'abcde':
        experiment = ROOT/'experiments/harness-comparison'/f'sec-{letter}-codex-deepseek-flash-1017-20261029'
        meta = yaml.safe_load((experiment/'meta_info.yaml').read_text())
        assert meta['experiment_id'] == experiment.name and meta['status'] == 'draft'
        phase = experiment/'test'
        accounting = read_json(phase/'traces/resource-accounting.json')
        snapshot = accounting['pricing_snapshot']
        assert snapshot['provider'] == 'DeepSeek' and snapshot['base_url'] == 'https://api.deepseek.com'
        assert snapshot['model'] == 'deepseek-flash'
        rates = {k:Decimal(v) for k,v in snapshot['usd_per_million_tokens'].items()}
        assert rates == {'prompt_tokens':Decimal('0.142857'), 'cached_tokens':Decimal('0.002857'), 'response_tokens':Decimal('0.571429')}
        rounds = []; resources = []; group_requests = 0
        for attempt in (1,2,3):
            path = phase/f'attempt-{attempt}.yaml'; rows = yaml.safe_load(path.read_text())
            assert len(rows) == 10
            baseline = None
            if args.base_ref:
                baseline = yaml.safe_load(subprocess.check_output(
                    ['git','show',f'{args.base_ref}:{path.relative_to(ROOT)}'], cwd=ROOT, text=True))
            for index, row in enumerate(rows):
                assert all(k in row and row[k] is not None for k in FIELDS), (path,index)
                assert set(row) <= {'source', *FIELDS, 'trace_filepath', 'error_reason'}
                assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', row['time'])
                assert row['score'] in (0,100)
                assert isinstance(row['duration_ms'],int) and row['duration_ms'] > 0
                if baseline:
                    for k in ('source','score','duration_ms'): assert row[k] == baseline[index][k], (path,index,k)
                source = row['source'][0]; assert len(row['source']) == 1
                assert source['benchmark_id'] == f'penguinharness-benchmark-sec-{letter}'
                assert (ROOT/'packages'/source['benchmark_id']/source['task_id']/'task_config.toml').exists()
                trace_path = phase/row['trace_filepath']; assert trace_path.is_file()
                lines = [json.loads(s,parse_float=Decimal) for s in trace_path.read_text().splitlines()]
                header, *requests = lines
                assert header['type'] == 'execution_resource_summary'
                assert header['task_id'] == source['task_id'] and header['attempt'] == attempt
                assert header['benchmark_id'] == source['benchmark_id']
                assert header['record_id'] not in ids; ids.add(header['record_id'])
                assert header['score'] == row['score']
                assert row['time'] == to_seconds(header['measurement_finished_at'])
                assert row['duration_ms'] == header['duration_ms']
                assert row['duration_ms'] == round((utc(header['agent_finished_at'])-utc(header['agent_started_at'])).total_seconds()*1000)
                assert header['trial_duration_ms'] == round((utc(header['trial_finished_at'])-utc(header['trial_started_at'])).total_seconds()*1000)
                assert utc(header['trial_started_at']) <= utc(header['agent_started_at']) < utc(header['agent_finished_at']) <= utc(header['trial_finished_at'])
                if 'verifier_recovery' in header:
                    recovery = header['verifier_recovery']
                    assert not recovery['agent_rerun'] and recovery['model_requests_added'] == 0
                    assert header['measurement_finished_at'] == recovery['finished_at']
                    assert utc(header['measurement_finished_at']) >= utc(header['trial_finished_at'])
                    counts['verifier_recovery'] += 1
                else: assert header['measurement_finished_at'] == header['trial_finished_at']
                assert (trace_path.parent/header['pricing_snapshot']).resolve() == (phase/'traces/resource-accounting.json').resolve()
                assert len(requests) == header['recorded_request_count']
                summed = Counter(); request_cost = Decimal(0); reasoning = 0
                for request in requests:
                    assert set(request) == {'type','response_id','session_id','timestamp','n_input_tokens','n_cache_tokens','n_output_tokens','n_total_tokens','n_reasoning_output_tokens','cost_usd','source_line'}
                    assert request['type'] == 'request_usage'
                    assert request['response_id'] not in response_ids; response_ids.add(request['response_id'])
                    assert all(type(request[k]) is int and request[k] >= 0 for k in (*TOKEN_FIELDS.values(),'n_reasoning_output_tokens'))
                    assert request['n_cache_tokens'] <= request['n_input_tokens']
                    assert request['n_reasoning_output_tokens'] <= request['n_output_tokens']
                    assert request['n_total_tokens'] == request['n_input_tokens']+request['n_output_tokens']
                    assert utc(header['agent_started_at']) <= utc(request['timestamp']) <= utc(header['agent_finished_at'])
                    tokens = {k:request[v] for k,v in TOKEN_FIELDS.items()}
                    tokens['cache_write'] = tokens['input']-tokens['cache_read']
                    close(request['cost_usd'], price(tokens,rates))
                    summed.update(tokens); request_cost += request['cost_usd']
                    reasoning += request['n_reasoning_output_tokens']
                assert dict(summed) == header['recorded_tokens']
                assert reasoning == header['recorded_reasoning_output_tokens']
                assert header['reasoning_included_in_output']
                close(header['recorded_cost_usd'], request_cost)
                reported = header['evaluation_tokens']; counts['measurements'] += 1
                if header['usage_complete']:
                    assert reported == dict(summed) and 'usage_estimate' not in header
                    assert header['evaluation_basis'] == 'observed'
                    close(header['full_cost_usd'], request_cost)
                    counts['observed'] += 1
                else:
                    assert header['full_cost_usd'] is None
                    assert header['evaluation_basis'] == 'observed_plus_estimated_request'
                    estimate = header['usage_estimate']
                    assert not estimate['is_measured'] and estimate['used_in_evaluation_fields']
                    assert estimate['assumed_missing_requests'] == 1 and estimate['reference_request_count'] == len(requests)
                    extra = estimate['additional_tokens']
                    for k in ('cache_read','cache_write','output'):
                        assert extra[k] == int((Decimal(summed[k])/len(requests)).quantize(Decimal(1),rounding=ROUND_HALF_UP))
                    assert extra['input'] == extra['cache_read']+extra['cache_write']
                    assert extra['total'] == extra['input']+extra['output']
                    assert reported == {k:summed[k]+extra[k] for k in summed}
                    close(estimate['estimated_additional_cost_usd'],price(extra,rates))
                    assert 'estimate' in row.get('error_reason','').lower()
                    counts['estimated'] += 1
                for k in ('input','cache_read','output'): assert row[TOKEN_FIELDS[k]] == reported[k]
                close(row['cost'],price(reported,rates)); close(header['evaluation_cost_usd'],price(reported,rates))
                assert all(re.fullmatch(r'[0-9a-f]{64}',v) for v in header['source_sha256'].values())
                assert not re.search(r'sk-[A-Za-z0-9]{16,}|Authorization:\s*Bearer|/home/[^/]+/|"api_key"',trace_path.read_text())
                resources.append(header); observed_total.update(summed); evaluation_total.update(reported)
                costs += Decimal(str(row['cost'])); group_requests += len(requests)
            rounds.append(rows)
        summary = yaml.safe_load((phase/'summary.yaml').read_text())
        assert summary['n_attempt'] == 3
        assert all(summary[k] is not None for k in ('time','score_mean','score_std','cost','duration_ms','n_input_tokens','n_cache_tokens','n_output_tokens'))
        scores = [statistics.mean(r['score'] for r in rows) for rows in rounds]
        assert abs(summary['score_mean']-statistics.mean(scores)) <= 0.005
        assert abs(summary['score_std']-statistics.stdev(scores)) <= 0.005
        assert summary['time'] == max(row['time'] for rows in rounds for row in rows)
        for k in ('duration_ms','n_input_tokens','n_cache_tokens','n_output_tokens','cost'):
            expected = sum(Decimal(str(r[k])) for rows in rounds for r in rows)/3
            close(summary[k],expected,'0.000001' if k != 'cost' else '0.000000000001')
        for key, data_key in [('recorded_tokens_all_attempts','recorded_tokens'),('evaluation_tokens_all_attempts','evaluation_tokens')]:
            for token in accounting[key]: assert accounting[key][token] == sum(r[data_key][token] for r in resources)
        close(accounting['recorded_cost_usd_all_attempts'],sum(r['recorded_cost_usd'] for r in resources))
        close(accounting['evaluation_cost_usd_all_attempts'],sum(r['evaluation_cost_usd'] for r in resources))
        assert accounting['recorded_requests'] == group_requests
        assert accounting['estimated_usage_executions'] == sum(not r['usage_complete'] for r in resources)
        aux_path = phase/'traces/auxiliary-executions.jsonl'
        auxiliary = [json.loads(s) for s in aux_path.read_text().splitlines()] if aux_path.exists() else []
        assert accounting['auxiliary_executions'] == len(auxiliary)
        for item in auxiliary:
            assert not item['included_in_evaluation_attempts'] and item['recorded_requests'] == 0
            assert not any(item['known_tokens'].values())
            assert item['record_id'] not in ids
            counts['auxiliary_executions'] += 1
        group_results.append({'group':letter.upper(),'round_scores':scores,'requests':group_requests,
            'time':summary['time'],'mean_cost_usd':summary['cost'],'estimated_executions':accounting['estimated_usage_executions']})
    assert counts == {'measurements':150,'observed':142,'estimated':8,'auxiliary_executions':5,'verifier_recovery':1},counts
    assert len(response_ids) == 7847 and observed_total['total'] == 831822252
    print(json.dumps({'validation':'passed','counts':dict(counts),'unique_requests':len(response_ids),
        'recorded_tokens':dict(observed_total),'evaluation_tokens_including_estimates':dict(evaluation_total),
        'evaluation_total_cost_usd':str(costs),'groups':group_results},indent=2))


if __name__ == '__main__':
    main()
