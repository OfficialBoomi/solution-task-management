-- MySQL Syntax

-- TABLES
-- Stores an access log when an identity service is provided
create table if not exists access_log
(
	login_pk int auto_increment
		primary key,
	user_email varchar(255) null,
	login_time timestamp null,
	flow_name varchar(255) null,
	flow_id varchar(255) null,
	tenant_id varchar(255) null,
	state_id varchar(255) null,
	version_id varchar(255) null,
	viewing_task_uuid_string varchar(255) null
);

-- Core table on which the task management framework runs. Projects, statuses, and types/initiatives are presented views from columns in this table
create table if not exists task
(
	task_pk int auto_increment
		primary key,
	task_subject varchar(255) null,
	task_description varchar(2500) null,
	task_uuid_string varchar(18) null,
	last_modified_timestamp timestamp null,
	created_timestamp timestamp null,
	completed_timestamp timestamp null,
	last_action_by varchar(255) null,
	created_by varchar(255) null,
	touch_count int null,
	status_message varchar(255) null,
	is_complete bit null,
	is_active_worklist bit null,
	task_type varchar(255) null,
	action_on varchar(255) null,
	parent_project varchar(255) null,
	task_url varchar(255) null
);

-- Stores task comment threads, displayed with a variation of the Boomi Bot Framework
create table if not exists task_comments
(
	comment_pk int auto_increment
		primary key,
	comment_body varchar(9999) null,
	commenter varchar(255) null,
	task_uuid_string varchar(20) null,
	comment_time timestamp null
);

-- Stores URLs associated with a task
create table if not exists task_urls
(
	url_pk int auto_increment
		primary key,
	asset_url varchar(255) null,
	asset_name varchar(999) null,
	related_task_uuid_string varchar(255) null,
	date_added timestamp null
);

-- VIEWS
-- Distinct task statuses used in any task
create or replace view v_task_statuses as select distinct task.status_message AS status_message
from task
where ((task.status_message is not null) and (task.status_message <> ''));

-- Distinct projects used in any task
create or replace view v_parent_projects as select distinct task.parent_project AS parent_project
from task
where ((task.parent_project is not null) and (task.parent_project <> ''));

-- Distinct task_types / 'initiatives' used in any task
create or replace view v_task_types as select distinct task.task_type AS task_type
from task
where ((task.task_type is not null) and (task.task_type <> ''));

-- Total and completed tasks grouped by task_type / 'initiative'
create or replace view v_initiative_task_count as select coalesce(nullif(a.task_type, ''), 'Unattached')               AS initiative,
       count('task_type')                                                AS total_initiative_tasks,
       count((case when (a.status_message = 'Complete') then 1 end)) AS completed_initiative_tasks
from task a
group by a.task_type
order by total_initiative_tasks desc;

-- Total and completed tasks grouped by parent_project
create or replace view v_project_task_count as select coalesce(nullif(a.parent_project, ''), 'Unattached')          AS parent_project,
       count('parent_project')                                           AS total_project_tasks,
       count((case when (a.status_message = 'Complete') then 1 end)) AS completed_project_tasks
from task a
group by a.parent_project
order by total_project_tasks desc;

-- Comment count by task
create or replace view v_task_comment_count as select a.task_uuid_string AS task_uuid_string, a.task_subject AS task_subject, count(b.task_uuid_string) AS comment_count
from (task a
         join task_comments b on ((a.task_uuid_string = b.task_uuid_string)))
group by a.task_uuid_string, a.task_subject;

-- Visit count by task
create or replace view v_task_visit_count as select a.task_uuid_string              AS task_uuid_string,
       a.task_subject           AS task_subject,
       count(b.viewing_task_uuid_string) AS view_count
from (task a
         join access_log b on ((a.task_uuid_string = b.viewing_task_uuid_string)))
group by a.task_uuid_string, a.task_subject;

-- Identity relevant views
-- Distinct users that have logged into the tool, if an identity source is added to the flows
create or replace view v_instance_users as select distinct access_log.user_email AS user_email
from access_log
where ((access_log.user_email is not null) and (access_log.user_email <> ''));

-- Last visit time by task, and visitor username if an idenfity source is added
create or replace view v_task_last_visitor as select a.task_uuid_string       AS task_uuid_string,
       a.task_subject    AS task_subject,
       max(b.login_time) AS last_visit,
       (select b.user_email
        from access_log b
        where (b.viewing_task_uuid_string = a.task_uuid_string)
        order by b.login_time desc
        limit 1)             AS last_visitor
from (task a
         join access_log b on ((a.task_uuid_string = b.viewing_task_uuid_string)))
group by a.task_uuid_string, a.task_subject;


-- Comment and view count grouped by task, and last visitor if identity source is added
create or replace view v_task_activity_insight as select a.task_uuid_string                  AS task_uuid_string,
       a.view_count                 AS view_count,
       b.last_visit                 AS last_visit,
       b.last_visitor               AS last_visitor,
       coalesce(c.comment_count, 0) AS comment_count
from ((v_task_visit_count a join v_task_last_visitor b on ((a.task_uuid_string = b.task_uuid_string)))
         left join v_task_comment_count c on ((a.task_uuid_string = c.task_uuid_string)))
group by a.task_uuid_string, a.task_subject;

-- Activity stream of comment posts and task create / update
create or replace view v_activity_stream as select ('task' collate utf8mb4_unicode_ci)                                                               AS action_type,
       a.last_action_by                                                                              AS actor,
       a.last_modified_timestamp                                                                     AS action_time,
       a.task_uuid_string                                                                                   AS task_uuid_string,
       concat(a.last_action_by, (case
                                         when (((select timestampdiff(SECOND, a.created_timestamp,
                                                                      a.last_modified_timestamp) AS result) <=
                                                '120') and (a.is_complete = TRUE))
                                             then ' CREATED and then pretty-much immediately COMPLETED '
                                         when (a.is_complete = TRUE) then ' COMPLETED '
                                         when ((select timestampdiff(SECOND, a.created_timestamp,
                                                                     a.last_modified_timestamp) AS result) <= '5')
                                             then ' CREATED '
                                         else ' UPDATED ' end), 'the task: ',
              upper(a.task_subject))                                                                 AS action_description
from task a
union all
select ('comment' collate utf8mb4_unicode_ci)              AS action_type,
       b.commenter                                         AS actor,
       b.comment_time                                      AS action_time,
       b.task_uuid_string                                           AS task_uuid_string,
       concat(b.commenter, ' COMMENTED on the task: ',
              upper((select a.task_subject from DUAL where (a.task_uuid_string = b.task_uuid_string))),
              ' with the message: "', b.comment_body, '"') AS action_description
from task_comments b
         join task a
group by action_description
order by action_time desc;

-- Total and completed tasks grouped by creator
create or replace view v_user_created_task_count as select coalesce(nullif(a.created_by, ''), 'Unattached')              AS task_creator,
       count('created_by')                                               AS total_user_created_tasks,
       count((case when (a.status_message = 'Complete') then 1 end)) AS completed_tasks
from task a
group by a.created_by
order by total_user_created_tasks desc;

-- Distinct projects grouped by task creator
create or replace view v_user_distinct_projects as select a.parent_project AS parent_project, a.created_by AS created_by
from task a
where ((a.parent_project is not null) and (a.parent_project <> ''))
group by a.parent_project, a.created_by;

-- Task count grouped by creator and task_type / 'initiative'
create or replace view v_user_initiative_task_count as select a.task_type        AS initiative,
       a.created_by       AS created_by,
       count(a.task_type) AS initiative_task_count
from task a
where ((a.task_type is not null) and (a.task_type <> ''))
group by a.task_type, a.created_by
order by initiative_task_count desc;

-- Project count grouped by creator and parent_project
create or replace view v_user_project_task_count as select a.parent_project        AS parent_project,
       a.created_by            AS created_by,
       count(a.parent_project) AS project_task_count
from task a
where ((a.parent_project is not null) and (a.parent_project <> ''))
group by a.parent_project, a.created_by
order by project_task_count desc;

-- Inserts three dummy tasks to populate the initial 'task statuses' of New, Complete, Working
INSERT INTO task (status_message, task_description)
values('New', 'Initial dummy task to populate task status of ''New''');

INSERT INTO task (status_message, task_description)
values('Complete', 'Initial dummy task to populate task status of ''Complete''');

INSERT INTO task (status_message, task_description)
values('Complete', 'Initial dummy task to populate task status of ''Working''');
