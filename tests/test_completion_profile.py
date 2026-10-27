"""Check the latency occupancy integral and payload units without hardware access."""
import importlib.util
from pathlib import Path


def test_completion_profile_units():
    path = Path(__file__).resolve().parents[1] / 'scripts/profile_completion_path.py'
    spec = importlib.util.spec_from_file_location('completion_profile', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    counts = dict.fromkeys(module.NAMES, 0)
    assert len(counts) == 32
    # Two overlapping bursts: occupancy 1 for 10 cycles, 2 for 20 cycles.
    counts.update(cycles=1000, pending_one=10, pending_two=20, r_bursts=2,
                  payload_dwords=32, completions=2, read_requests=1,
                  slot_empty_wait=100, tx_stall=20)
    result = module.summarize(counts, 125000000)
    assert result['mean_axi_burst_residence_ns'] == 200
    assert result['mean_completion_payload_bytes'] == 64
    assert result['mean_read_request_payload_bytes'] == 128
    assert result['completion_payload_MB_s'] == 16
    assert result['cycle_percent']['slot_empty_wait'] == 10
    assert result['tx_stall_cycles_per_completion'] == 10

    # The same occupancy counters cannot represent owners 3..8, and wide
    # header/payload-sharing beats cannot be multiplied by eight for bytes.
    wide = module.summarize(counts, 125000000, packet_dwords=2, read_slots=8)
    for name in ('mean_axi_burst_residence_ns', 'mean_completion_payload_bytes',
                 'mean_read_request_payload_bytes', 'completion_payload_MB_s'):
        assert wide[name] is None
    assert wide['cycle_percent']['slot_empty_wait'] == 10
