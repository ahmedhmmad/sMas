-- يُلحَق بعد كل ملف V: يطبع الدليل الخام ثم يلغي كل شيء
reset role;
select '# ' || k || ' = ' || v from m00_res order by k;
rollback;
