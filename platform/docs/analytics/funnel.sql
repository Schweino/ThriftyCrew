-- Workers Analytics Engine dataset: tc_grocery_funnel
-- blob1 event, blob2 path, blob3 member tier, blob4 release id,
-- blob5 product/surface, double1 count, double2 client event epoch ms.
SELECT
  blob2 AS path,
  blob3 AS member_tier,
  SUM(IF(blob1 = 'view', double1, 0)) AS views,
  SUM(IF(blob1 = 'tool_use', double1, 0)) AS tool_uses,
  SUM(IF(blob1 = 'signup_click', double1, 0)) AS signup_clicks,
  SUM(IF(blob1 = 'join_attempt', double1, 0)) AS join_attempts,
  IF(views = 0, 0, tool_uses / views) AS view_to_tool_rate,
  IF(tool_uses = 0, 0, signup_clicks / tool_uses) AS tool_to_signup_rate,
  IF(signup_clicks = 0, 0, join_attempts / signup_clicks) AS signup_to_join_rate
FROM tc_grocery_funnel
WHERE timestamp >= NOW() - INTERVAL '30' DAY
GROUP BY path, member_tier
ORDER BY views DESC;
