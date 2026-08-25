function ok = gcc_ab(a, b)
% GCC_AB — compare two mex_run result cells (x86sim track vs gcc track).
% Prints PARITY FAIL details on mismatch; prints PARITY OK on equality.
ok = 1;
if numel(a) ~= numel(b)
	fprintf('PARITY FAIL: nouts %d vs %d\n', numel(a), numel(b));
	ok = 0;
	return;
end
for k = 1:numel(a)
	if ~isequal(a{k}, b{k})
		fprintf('PARITY FAIL: out %d differs\n', k);
		ok = 0;
		return;
	end
end
fprintf('PARITY OK\n');
end
