# Ansible Roles

Create one directory per reusable role. Typical role structure:

```text
roles/example_role/
├── defaults/main.yml
├── handlers/main.yml
├── tasks/main.yml
├── templates/
└── files/
```

Keep role defaults safe, document required variables, and test changes on a non-production host first.
